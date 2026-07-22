package main

import (
	"bytes"
	"compress/zlib"
	"encoding/base64"
	"fmt"
	"io"
	"strings"
)

// decodePobCode reverses the PoB code encoding used on the wire: URL-safe
// base64 wrapping a zlib-deflated XML document. Mirrors
// pob_wrapper/Runtime/Shared.lua's decodePobCode/applyConfigAndExport pair.
func decodePobCode(data []byte) (string, error) {
	compressed, err := base64.URLEncoding.DecodeString(strings.TrimSpace(string(data)))
	if err != nil {
		return "", fmt.Errorf("base64 decoding pob code: %w", err)
	}
	reader, err := zlib.NewReader(bytes.NewReader(compressed))
	if err != nil {
		return "", fmt.Errorf("opening zlib stream: %w", err)
	}
	defer reader.Close()
	xmlBytes, err := io.ReadAll(reader)
	if err != nil {
		return "", fmt.Errorf("inflating pob code: %w", err)
	}
	return string(xmlBytes), nil
}

type diffOp struct {
	kind  byte // 'e' (equal), 'd' (delete), 'i' (insert)
	aLine int  // 1-indexed line in `before`, valid for equal/delete
	bLine int  // 1-indexed line in `after`, valid for equal/insert
}

// myersDiff computes the shortest edit script between a and b using Myers'
// O(ND) algorithm, returned as an in-order list of line-level operations.
func myersDiff(a, b []string) []diffOp {
	n, m := len(a), len(b)
	max := n + m
	v := map[int]int{1: 0}
	var trace []map[int]int

	d := max
	for step := 0; step <= max; step++ {
		snapshot := make(map[int]int, len(v))
		for k, val := range v {
			snapshot[k] = val
		}
		trace = append(trace, snapshot)

		found := false
		for k := -step; k <= step; k += 2 {
			var x int
			if k == -step || (k != step && v[k-1] < v[k+1]) {
				x = v[k+1]
			} else {
				x = v[k-1] + 1
			}
			y := x - k
			for x < n && y < m && a[x] == b[y] {
				x++
				y++
			}
			v[k] = x
			if x >= n && y >= m {
				found = true
				break
			}
		}
		if found {
			d = step
			break
		}
	}

	var ops []diffOp
	x, y := n, m
	for step := d; step >= 0; step-- {
		v := trace[step]
		k := x - y
		var prevK int
		if k == -step || (k != step && v[k-1] < v[k+1]) {
			prevK = k + 1
		} else {
			prevK = k - 1
		}
		prevX := v[prevK]
		prevY := prevX - prevK

		for x > prevX && y > prevY {
			ops = append(ops, diffOp{kind: 'e', aLine: x, bLine: y})
			x--
			y--
		}
		if step > 0 {
			if x == prevX {
				ops = append(ops, diffOp{kind: 'i', bLine: prevY + 1})
			} else {
				ops = append(ops, diffOp{kind: 'd', aLine: prevX + 1})
			}
		}
		x, y = prevX, prevY
	}

	for i, j := 0, len(ops)-1; i < j; i, j = i+1, j-1 {
		ops[i], ops[j] = ops[j], ops[i]
	}
	return ops
}

// unifiedXMLDiff renders a diff(1)-style unified diff between before and
// after, with contextSize lines of unchanged context around each hunk.
// Returns "" if the two documents are identical.
func unifiedXMLDiff(before, after string, contextSize int) string {
	a := strings.Split(before, "\n")
	b := strings.Split(after, "\n")
	ops := myersDiff(a, b)

	type hunkRange struct{ start, end int } // indices into ops, inclusive
	var hunks []hunkRange
	total := len(ops)
	for i := 0; i < total; {
		if ops[i].kind == 'e' {
			i++
			continue
		}
		hunkStart := i - contextSize
		if hunkStart < 0 {
			hunkStart = 0
		}
		hunkEnd := i
		scan := i
		for scan < total {
			if ops[scan].kind != 'e' {
				hunkEnd = scan
				scan++
				continue
			}
			runStart := scan
			for scan < total && ops[scan].kind == 'e' {
				scan++
			}
			if scan >= total || scan-runStart > contextSize*2 {
				break
			}
			hunkEnd = scan - 1
		}
		if extended := hunkEnd + contextSize; extended < total-1 {
			hunkEnd = extended
		} else {
			hunkEnd = total - 1
		}
		hunks = append(hunks, hunkRange{hunkStart, hunkEnd})
		i = hunkEnd + 1
	}

	if len(hunks) == 0 {
		return ""
	}

	var out strings.Builder
	for hi, hunk := range hunks {
		if hi > 0 {
			out.WriteByte('\n')
		}
		var aStart, bStart, aCount, bCount int
		aStart, bStart = -1, -1
		for i := hunk.start; i <= hunk.end; i++ {
			op := ops[i]
			switch op.kind {
			case 'e':
				if aStart == -1 {
					aStart = op.aLine
				}
				if bStart == -1 {
					bStart = op.bLine
				}
				aCount++
				bCount++
			case 'd':
				if aStart == -1 {
					aStart = op.aLine
				}
				aCount++
			case 'i':
				if bStart == -1 {
					bStart = op.bLine
				}
				bCount++
			}
		}
		if aStart == -1 {
			aStart = 0
		}
		if bStart == -1 {
			bStart = 0
		}
		fmt.Fprintf(&out, "@@ -%d,%d +%d,%d @@\n", aStart, aCount, bStart, bCount)
		for i := hunk.start; i <= hunk.end; i++ {
			op := ops[i]
			switch op.kind {
			case 'e':
				out.WriteString(" ")
				out.WriteString(a[op.aLine-1])
				out.WriteString("\n")
			case 'd':
				out.WriteString("-")
				out.WriteString(a[op.aLine-1])
				out.WriteString("\n")
			case 'i':
				out.WriteString("+")
				out.WriteString(b[op.bLine-1])
				out.WriteString("\n")
			}
		}
	}
	return strings.TrimRight(out.String(), "\n")
}
