package agent

import "core:encoding/base64"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

INLINE_TEXT_LIMIT :: 100_000

@(private)
is_image :: proc(a: Attachment) -> bool {
	switch a.mime {
	case "image/png", "image/jpeg", "image/gif", "image/webp":
		return len(a.data) > 0 || a.path != ""
	}
	return false
}

@(private)
is_pdf :: proc(a: Attachment) -> bool {
	return a.mime == "application/pdf" && len(a.data) > 0
}

@(private)
is_text :: proc(a: Attachment) -> bool {
	if strings.has_prefix(a.mime, "text/") {
		return true
	}
	switch a.mime {
	case "application/json", "application/xml", "application/javascript", "application/x-yaml", "application/toml":
		return true
	case "":
		if len(a.data) == 0 || !utf8.valid_string(string(a.data)) {
			return false
		}
		for c in a.data {
			if c == 0 {
				return false
			}
		}
		return true
	}
	return false
}

@(private)
file_name :: proc(a: Attachment) -> string {
	if a.name != "" {
		return a.name
	}
	if i := strings.last_index_byte(a.path, '/'); i >= 0 {
		return a.path[i + 1:]
	}
	return a.path != "" ? a.path : "attachment"
}

@(private)
b64 :: proc(data: []u8) -> string {
	s, _ := base64.encode(data, allocator = context.temp_allocator)
	return s
}

@(private)
file_uri :: proc(path: string) -> string {
	return strings.concatenate({"file://", path}, context.temp_allocator)
}

@(private)
mime_or :: proc(a: Attachment) -> string {
	if a.mime != "" {
		return a.mime
	}
	return is_text(a) ? "text/plain" : "application/octet-stream"
}

@(private)
attachment_note :: proc(a: Attachment, inline: bool) -> string {
	b := make([dynamic]u8, context.temp_allocator)
	put(&b, "[Attached file: ", file_name(a))
	if a.path != "" && a.path != file_name(a) {
		put(&b, " at ", a.path)
	}
	if a.mime != "" {
		put(&b, ", ", a.mime)
	}
	if len(a.data) > 0 {
		buf: [32]u8
		put(&b, ", ", strconv.write_int(buf[:], i64(len(a.data)), 10), " bytes")
	}
	append(&b, "]")
	if inline && is_text(a) && len(a.data) > 0 && len(a.data) <= INLINE_TEXT_LIMIT {
		put(&b, "\n```\n", string(a.data))
		if a.data[len(a.data) - 1] != '\n' {
			append(&b, "\n")
		}
		append(&b, "```")
	}
	return string(b[:])
}

@(private)
with_notes :: proc(text: string, notes: []string) -> string {
	if len(notes) == 0 {
		return text
	}
	b := make([dynamic]u8, context.temp_allocator)
	append(&b, text)
	for n in notes {
		if len(b) > 0 {
			append(&b, "\n\n")
		}
		append(&b, n)
	}
	return string(b[:])
}
