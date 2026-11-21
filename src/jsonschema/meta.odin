package jsonschema

embedded :: proc "contextless" (uri: string) -> ([]u8, bool) {
	switch uri {
	case "https://json-schema.org/draft/2020-12/schema":
		return #load("meta/schema.json"), true
	case "https://json-schema.org/draft/2020-12/meta/core":
		return #load("meta/meta_core.json"), true
	case "https://json-schema.org/draft/2020-12/meta/applicator":
		return #load("meta/meta_applicator.json"), true
	case "https://json-schema.org/draft/2020-12/meta/unevaluated":
		return #load("meta/meta_unevaluated.json"), true
	case "https://json-schema.org/draft/2020-12/meta/validation":
		return #load("meta/meta_validation.json"), true
	case "https://json-schema.org/draft/2020-12/meta/meta-data":
		return #load("meta/meta_meta-data.json"), true
	case "https://json-schema.org/draft/2020-12/meta/format-annotation":
		return #load("meta/meta_format-annotation.json"), true
	case "https://json-schema.org/draft/2020-12/meta/content":
		return #load("meta/meta_content.json"), true
	}
	return nil, false
}
