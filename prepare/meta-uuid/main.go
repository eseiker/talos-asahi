// SPDX-License-Identifier: MPL-2.0

// meta-uuid initializes Talos UUIDOverride in a META partition.
package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
)

const (
	advLength       = 256 * 1024
	advCopies       = 2
	advSize         = advLength * advCopies
	advMagic1       = uint32(0x5a4b3c2d)
	advMagic2       = uint32(0xa5b4c3d2)
	uuidOverrideTag = uint32(0x0f)
)

type adv map[uint32][]byte

func main() {
	if len(os.Args) < 2 || len(os.Args) > 3 {
		fmt.Fprintf(os.Stderr, "usage: %s DEVICE_OR_IMAGE [BYTE_OFFSET]\n", os.Args[0])

		os.Exit(2)
	}

	offset := int64(0)
	if len(os.Args) == 3 {
		var err error

		offset, err = strconv.ParseInt(os.Args[2], 10, 64)
		if err != nil || offset < 0 {
			fmt.Fprintf(os.Stderr, "invalid byte offset: %s\n", os.Args[2])

			os.Exit(2)
		}
	}

	uuid, created, err := ensureUUID(os.Args[1], offset)
	if err != nil {
		fmt.Fprintf(os.Stderr, "META UUID initialization failed: %v\n", err)

		os.Exit(1)
	}

	if created {
		fmt.Printf("generated UUIDOverride %s\n", uuid)
	} else {
		fmt.Printf("preserved UUIDOverride %s\n", uuid)
	}
}

func ensureUUID(path string, offset int64) (string, bool, error) {
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return "", false, err
	}

	defer f.Close() //nolint:errcheck

	serialized := make([]byte, advSize)
	if _, err = f.ReadAt(serialized, offset); err != nil {
		return "", false, fmt.Errorf("read ADV at offset %d: %w", offset, err)
	}

	tags, err := parseRedundantADV(serialized)
	if err != nil {
		return "", false, err
	}

	uuid := ""
	created := false
	if value, ok := tags[uuidOverrideTag]; ok {
		uuid = string(value)
		if !validUUID(uuid) {
			return "", false, fmt.Errorf("existing UUIDOverride is invalid: %q", uuid)
		}
	} else {
		uuid, err = newUUID()
		if err != nil {
			return "", false, err
		}

		tags[uuidOverrideTag] = []byte(uuid)
		created = true
	}

	block, err := marshalADV(tags)
	if err != nil {
		return "", false, err
	}

	serialized = append(append(make([]byte, 0, advSize), block...), block...)
	if _, err = f.WriteAt(serialized, offset); err != nil {
		return "", false, fmt.Errorf("write ADV at offset %d: %w", offset, err)
	}

	if err = f.Sync(); err != nil {
		return "", false, fmt.Errorf("sync ADV: %w", err)
	}

	verify := make([]byte, advSize)
	if _, err = f.ReadAt(verify, offset); err != nil {
		return "", false, fmt.Errorf("read back ADV: %w", err)
	}

	for copyIndex := range advCopies {
		start := copyIndex * advLength
		verifiedTags, verifyErr := unmarshalADV(bytes.Clone(verify[start : start+advLength]))
		if verifyErr != nil {
			return "", false, fmt.Errorf("verify ADV copy %d: %w", copyIndex+1, verifyErr)
		}

		if !bytes.Equal(verifiedTags[uuidOverrideTag], []byte(uuid)) {
			return "", false, fmt.Errorf("UUIDOverride read-back mismatch in ADV copy %d", copyIndex+1)
		}
	}

	return uuid, created, nil
}

func parseRedundantADV(serialized []byte) (adv, error) {
	if len(serialized) != advSize {
		return nil, fmt.Errorf("ADV must be %d bytes, got %d", advSize, len(serialized))
	}

	first, firstErr := unmarshalADV(bytes.Clone(serialized[:advLength]))
	if firstErr == nil {
		return first, nil
	}

	second, secondErr := unmarshalADV(bytes.Clone(serialized[advLength:]))
	if secondErr == nil {
		return second, nil
	}

	if allZero(serialized) {
		return adv{}, nil
	}

	return nil, fmt.Errorf("both ADV copies are invalid: first: %v; second: %v", firstErr, secondErr)
}

func unmarshalADV(block []byte) (adv, error) {
	if len(block) != advLength {
		return nil, fmt.Errorf("ADV block must be %d bytes", advLength)
	}

	if binary.BigEndian.Uint32(block[:4]) != advMagic1 {
		return nil, errors.New("bad leading magic")
	}

	if binary.BigEndian.Uint32(block[len(block)-4:]) != advMagic2 {
		return nil, errors.New("bad trailing magic")
	}

	wantChecksum := bytes.Clone(block[len(block)-36 : len(block)-4])
	clear(block[len(block)-36 : len(block)-4])
	gotChecksum := sha256.Sum256(block)
	if !bytes.Equal(wantChecksum, gotChecksum[:]) {
		return nil, errors.New("checksum mismatch")
	}

	tags := adv{}
	data := block[4 : len(block)-36]
	for len(data) >= 8 {
		tag := binary.BigEndian.Uint32(data[:4])
		if tag == 0 {
			break
		}

		size := binary.BigEndian.Uint32(data[4:8])
		if uint64(size)+8 > uint64(len(data)) {
			return nil, fmt.Errorf("tag %d extends past ADV data", tag)
		}

		if tag > 0xff {
			return nil, fmt.Errorf("unsupported tag %d", tag)
		}

		tags[tag] = bytes.Clone(data[8 : 8+size])
		data = data[8+size:]
	}

	return tags, nil
}

func marshalADV(tags adv) ([]byte, error) {
	block := make([]byte, advLength)
	binary.BigEndian.PutUint32(block[:4], advMagic1)
	binary.BigEndian.PutUint32(block[len(block)-4:], advMagic2)

	keys := make([]int, 0, len(tags))
	for tag := range tags {
		if tag == 0 || tag > 0xff {
			return nil, fmt.Errorf("unsupported tag %d", tag)
		}

		keys = append(keys, int(tag))
	}

	sort.Ints(keys)
	data := block[4 : len(block)-36]
	for _, key := range keys {
		value := tags[uint32(key)]
		if len(value)+8 > len(data) {
			return nil, fmt.Errorf("ADV overflows while writing tag %d", key)
		}

		binary.BigEndian.PutUint32(data[:4], uint32(key))
		binary.BigEndian.PutUint32(data[4:8], uint32(len(value)))
		copy(data[8:], value)
		data = data[8+len(value):]
	}

	checksum := sha256.Sum256(block)
	copy(block[len(block)-36:len(block)-4], checksum[:])

	return block, nil
}

func newUUID() (string, error) {
	value := make([]byte, 16)
	if _, err := io.ReadFull(rand.Reader, value); err != nil {
		return "", fmt.Errorf("generate UUID: %w", err)
	}

	value[6] = value[6]&0x0f | 0x40
	value[8] = value[8]&0x3f | 0x80

	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		value[0:4], value[4:6], value[6:8], value[8:10], value[10:16]), nil
}

func validUUID(value string) bool {
	if len(value) != 36 {
		return false
	}

	for i, char := range strings.ToLower(value) {
		switch i {
		case 8, 13, 18, 23:
			if char != '-' {
				return false
			}
		default:
			if !strings.ContainsRune("0123456789abcdef", char) {
				return false
			}
		}
	}

	return value != "00000000-0000-0000-0000-000000000000"
}

func allZero(value []byte) bool {
	for _, item := range value {
		if item != 0 {
			return false
		}
	}

	return true
}
