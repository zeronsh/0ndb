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
	case "https://json-schema.org/draft/2019-09/schema":
		return #load("meta/draft_2019-09_schema.json"), true
	case "https://json-schema.org/draft/2019-09/meta/core":
		return #load("meta/draft_2019-09_meta_core.json"), true
	case "https://json-schema.org/draft/2019-09/meta/applicator":
		return #load("meta/draft_2019-09_meta_applicator.json"), true
	case "https://json-schema.org/draft/2019-09/meta/validation":
		return #load("meta/draft_2019-09_meta_validation.json"), true
	case "https://json-schema.org/draft/2019-09/meta/meta-data":
		return #load("meta/draft_2019-09_meta_meta-data.json"), true
	case "https://json-schema.org/draft/2019-09/meta/format":
		return #load("meta/draft_2019-09_meta_format.json"), true
	case "https://json-schema.org/draft/2019-09/meta/content":
		return #load("meta/draft_2019-09_meta_content.json"), true
	case "http://json-schema.org/draft-07/schema":
		return #load("meta/draft-07_schema.json"), true
	case "http://json-schema.org/draft-06/schema":
		return #load("meta/draft-06_schema.json"), true
	case "http://json-schema.org/draft-04/schema":
		return #load("meta/draft-04_schema.json"), true
	}
	return nil, false
}
