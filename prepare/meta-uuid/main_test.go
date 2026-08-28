// SPDX-License-Identifier: MPL-2.0

package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestEnsureUUID(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "disk.img")
	offset := int64(1024 * 1024)
	content := make([]byte, offset+1024*1024)
	block, err := marshalADV(adv{3: []byte("preserve-tag")})
	if err != nil {
		t.Fatal(err)
	}
	copy(content[offset:], append(block, block...))
	copy(content[offset+700*1024:], "preserve-outside-adv")

	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}

	first, created, err := ensureUUID(path, offset)
	if err != nil {
		t.Fatal(err)
	}

	if !created || !validUUID(first) {
		t.Fatalf("expected a generated UUID, got %q created=%v", first, created)
	}

	second, created, err := ensureUUID(path, offset)
	if err != nil {
		t.Fatal(err)
	}

	if created || second != first {
		t.Fatalf("expected UUID %q to be preserved, got %q created=%v", first, second, created)
	}

	updated, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	if !bytes.Equal(updated[offset+700*1024:offset+700*1024+20], []byte("preserve-outside-adv")) {
		t.Fatal("data outside Talos ADV was modified")
	}

	tags, err := parseRedundantADV(updated[offset : offset+advSize])
	if err != nil {
		t.Fatal(err)
	}
	if string(tags[3]) != "preserve-tag" {
		t.Fatalf("existing META tag was modified: %q", tags[3])
	}
}

func TestRecoversFromSecondCopy(t *testing.T) {
	t.Parallel()

	tags := adv{3: []byte("preserved")}
	block, err := marshalADV(tags)
	if err != nil {
		t.Fatal(err)
	}

	first := bytes.Clone(block)
	first[0] = 0
	parsed, err := parseRedundantADV(append(first, block...))
	if err != nil {
		t.Fatal(err)
	}

	if string(parsed[3]) != "preserved" {
		t.Fatalf("unexpected recovered value %q", parsed[3])
	}
}

func TestRejectsMalformedNonzeroADV(t *testing.T) {
	t.Parallel()

	malformed := make([]byte, advSize)
	copy(malformed, "not-an-adv")

	if _, err := parseRedundantADV(malformed); err == nil {
		t.Fatal("expected malformed nonzero ADV to be rejected")
	}
}

func TestRejectsInvalidExistingUUID(t *testing.T) {
	t.Parallel()

	tags := adv{uuidOverrideTag: []byte("not-a-uuid")}
	block, err := marshalADV(tags)
	if err != nil {
		t.Fatal(err)
	}

	path := filepath.Join(t.TempDir(), "meta.img")
	if err = os.WriteFile(path, append(block, block...), 0o600); err != nil {
		t.Fatal(err)
	}

	if _, _, err = ensureUUID(path, 0); err == nil {
		t.Fatal("expected invalid UUIDOverride to be rejected")
	}
}
