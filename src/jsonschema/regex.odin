package jsonschema

import "base:runtime"
import "core:unicode"
import "core:unicode/utf8"

REGEX_STEP_LIMIT :: 2_000_000
REGEX_MAX_REPEAT :: 1000

Regex :: struct {
	prog:   []Inst,
	groups: int,
	slots:  int,
	ranges: [][2]rune,
	subs:   [][]Inst,
	names:  []string,
}

Regex_Result :: enum u8 {
	No_Match,
	Match,
	Too_Complex,
}

@(private)
Op :: enum u8 {
	Char,
	Any,
	Class,
	Not_Class,
	Split,
	Jmp,
	Save,
	Mark,
	Check,
	Bol,
	Eol,
	Word,
	Not_Word,
	Backref,
	Look,
	Match,
}

@(private)
Pred :: enum u8 {
	Digit,
	Not_Digit,
	Word,
	Not_Word,
	Space,
	Not_Space,
	Letter,
	Upper,
	Lower,
	Title,
	Other_Letter,
	Mark,
	Number,
	Decimal,
	Other_Number,
	Punct,
	Symbol,
	Separator,
	Control,
	Any,
	Ascii,
}

@(private)
Class_Item :: struct {
	lo:    rune,
	hi:    rune,
	pred:  Pred,
	is_p:  bool,
	neg_p: bool,
}

@(private)
Inst :: struct {
	op:     Op,
	r:      rune,
	x:      int,
	y:      int,
	items:  []Class_Item,
	neg:    bool,
	behind: bool,
}

@(private)
Node_Kind :: enum u8 {
	Empty,
	Char,
	Any,
	Class,
	Concat,
	Alt,
	Repeat,
	Group,
	Bol,
	Eol,
	Word,
	Not_Word,
	Backref,
	Look,
}

@(private)
Node :: struct {
	kind:    Node_Kind,
	r:       rune,
	items:   []Class_Item,
	neg:     bool,
	kids:    [dynamic]^Node,
	min:     int,
	max:     int,
	greedy:  bool,
	group:   int,
	behind:  bool,
	name:    string,
}

@(private)
Rparser :: struct {
	src:    []rune,
	i:      int,
	groups: int,
	names:  [dynamic]string,
	refs:   [dynamic]^Node,
	a:      runtime.Allocator,
	ok:     bool,
}

regex_compile :: proc(pattern: string, allocator := context.allocator) -> (rx: Regex, ok: bool) {
	context.allocator = allocator
	runes := make([dynamic]rune, context.temp_allocator)
	for r in pattern {
		append(&runes, r)
	}
	p := Rparser {
		src   = runes[:],
		ok    = true,
		a     = allocator,
		names = make([dynamic]string, context.temp_allocator),
		refs  = make([dynamic]^Node, context.temp_allocator),
	}
	append(&p.names, "")
	n := r_alt(&p)
	if !p.ok || p.i != len(p.src) {
		return {}, false
	}
	for ref in p.refs {
		if ref.name != "" {
			found := false
			for nm, gi in p.names {
				if nm == ref.name {
					ref.group = gi
					found = true
				}
			}
			if !found {
				return {}, false
			}
		}
		if ref.group > p.groups {
			ref.kind = .Empty
		}
	}
	c := Rcomp {
		prog = make([dynamic]Inst, context.temp_allocator),
		subs = make([dynamic][]Inst, context.temp_allocator),
	}
	emit_node(&c, n)
	append(&c.prog, Inst{op = .Match})
	if !ok_size(&c) {
		return {}, false
	}
	rx.prog = clone_prog(c.prog[:])
	rx.subs = make([][]Inst, len(c.subs))
	for s, i in c.subs {
		rx.subs[i] = clone_prog(s)
	}
	rx.groups = p.groups
	rx.slots = c.slots
	return rx, true
}

@(private)
clone_prog :: proc(src: []Inst) -> []Inst {
	out := make([]Inst, len(src))
	for ins, i in src {
		out[i] = ins
		if len(ins.items) > 0 {
			items := make([]Class_Item, len(ins.items))
			copy(items, ins.items)
			out[i].items = items
		}
	}
	return out
}

@(private)
new_node :: proc(p: ^Rparser, kind: Node_Kind) -> ^Node {
	n := new(Node, context.temp_allocator)
	n.kind = kind
	n.kids = make([dynamic]^Node, context.temp_allocator)
	return n
}

@(private)
peek :: proc(p: ^Rparser) -> rune {
	return p.i < len(p.src) ? p.src[p.i] : -1
}

@(private)
r_alt :: proc(p: ^Rparser) -> ^Node {
	first := r_concat(p)
	if peek(p) != '|' {
		return first
	}
	alt := new_node(p, .Alt)
	append(&alt.kids, first)
	for peek(p) == '|' {
		p.i += 1
		append(&alt.kids, r_concat(p))
	}
	return alt
}

@(private)
r_concat :: proc(p: ^Rparser) -> ^Node {
	cat := new_node(p, .Concat)
	for p.ok && p.i < len(p.src) && peek(p) != '|' && peek(p) != ')' {
		atom := r_atom(p)
		if !p.ok {
			return cat
		}
		append(&cat.kids, r_quant(p, atom))
	}
	return cat
}

@(private)
r_number :: proc(p: ^Rparser) -> (int, bool) {
	n := 0
	start := p.i
	for p.i < len(p.src) && p.src[p.i] >= '0' && p.src[p.i] <= '9' {
		n = min(n * 10 + int(p.src[p.i] - '0'), 1 << 30)
		p.i += 1
	}
	return n, p.i > start
}

@(private)
r_quant :: proc(p: ^Rparser, atom: ^Node) -> ^Node {
	c := peek(p)
	lo, hi := -1, -1
	switch c {
	case '*':
		lo, hi = 0, -1
		p.i += 1
	case '+':
		lo, hi = 1, -1
		p.i += 1
	case '?':
		lo, hi = 0, 1
		p.i += 1
	case '{':
		save := p.i
		p.i += 1
		a, ok := r_number(p)
		if !ok {
			p.ok = false
			return atom
		}
		lo = a
		hi = a
		if peek(p) == ',' {
			p.i += 1
			if b, bok := r_number(p); bok {
				hi = b
			} else {
				hi = -1
			}
		}
		if peek(p) != '}' {
			p.i = save
			p.ok = false
			return atom
		}
		p.i += 1
		if hi >= 0 && hi < lo {
			p.ok = false
			return atom
		}
	case:
		return atom
	}
	if atom.kind == .Bol || atom.kind == .Eol || atom.kind == .Word || atom.kind == .Not_Word || (atom.kind == .Look && atom.behind) {
		p.ok = false
		return atom
	}
	greedy := true
	if peek(p) == '?' {
		greedy = false
		p.i += 1
	}
	n := new_node(p, .Repeat)
	append(&n.kids, atom)
	n.min = lo
	n.max = hi
	n.greedy = greedy
	return n
}

@(private)
r_atom :: proc(p: ^Rparser) -> ^Node {
	c := p.src[p.i]
	switch c {
	case '^':
		p.i += 1
		return new_node(p, .Bol)
	case '$':
		p.i += 1
		return new_node(p, .Eol)
	case '.':
		p.i += 1
		return new_node(p, .Any)
	case '(':
		return r_group(p)
	case '[':
		return r_class(p)
	case '\\':
		return r_escape(p)
	case '*', '+', '?', '{', '}', ']', ')':
		p.ok = false
		return new_node(p, .Empty)
	}
	p.i += 1
	n := new_node(p, .Char)
	n.r = c
	return n
}

@(private)
r_group :: proc(p: ^Rparser) -> ^Node {
	p.i += 1
	if peek(p) == '?' {
		p.i += 1
		k := peek(p)
		switch k {
		case ':':
			p.i += 1
			inner := r_alt(p)
			r_close(p)
			return inner
		case '=', '!':
			p.i += 1
			n := new_node(p, .Look)
			n.neg = k == '!'
			append(&n.kids, r_alt(p))
			r_close(p)
			return n
		case '<':
			p.i += 1
			k2 := peek(p)
			if k2 == '=' || k2 == '!' {
				p.i += 1
				n := new_node(p, .Look)
				n.neg = k2 == '!'
				n.behind = true
				append(&n.kids, r_alt(p))
				r_close(p)
				return n
			}
			start := p.i
			for p.i < len(p.src) && p.src[p.i] != '>' {
				p.i += 1
			}
			if p.i >= len(p.src) || p.i == start {
				p.ok = false
				return new_node(p, .Empty)
			}
			name := utf8.runes_to_string(p.src[start:p.i], context.temp_allocator)
			p.i += 1
			for nm in p.names {
				if nm == name {
					p.ok = false
				}
			}
			p.groups += 1
			append(&p.names, name)
			n := new_node(p, .Group)
			n.group = p.groups
			append(&n.kids, r_alt(p))
			r_close(p)
			return n
		}
		p.ok = false
		return new_node(p, .Empty)
	}
	p.groups += 1
	append(&p.names, "")
	n := new_node(p, .Group)
	n.group = p.groups
	append(&n.kids, r_alt(p))
	r_close(p)
	return n
}

@(private)
r_close :: proc(p: ^Rparser) {
	if peek(p) != ')' {
		p.ok = false
		return
	}
	p.i += 1
}

@(private)
r_hex :: proc(p: ^Rparser, n: int) -> (rune, bool) {
	if p.i + n > len(p.src) {
		return 0, false
	}
	v: rune
	for k in 0 ..< n {
		d, ok := hexdigit(u8(p.src[p.i + k]) if p.src[p.i + k] < 128 else 'z')
		if !ok {
			return 0, false
		}
		v = v * 16 + rune(d)
	}
	p.i += n
	return v, true
}

@(private)
r_unicode_escape :: proc(p: ^Rparser) -> (rune, bool) {
	if peek(p) == '{' {
		p.i += 1
		v: rune
		digits := 0
		for p.i < len(p.src) && p.src[p.i] != '}' {
			c := p.src[p.i]
			d, ok := hexdigit(u8(c) if c < 128 else 'z')
			if !ok {
				return 0, false
			}
			v = v * 16 + rune(d)
			if v > 0x10ffff {
				return 0, false
			}
			digits += 1
			p.i += 1
		}
		if peek(p) != '}' || digits == 0 {
			return 0, false
		}
		p.i += 1
		return v, true
	}
	hi, ok := r_hex(p, 4)
	if !ok {
		return 0, false
	}
	if hi >= 0xd800 && hi < 0xdc00 && p.i + 6 <= len(p.src) && p.src[p.i] == '\\' && p.src[p.i + 1] == 'u' {
		save := p.i
		p.i += 2
		if lo, lok := r_hex(p, 4); lok && lo >= 0xdc00 && lo < 0xe000 {
			return 0x10000 + ((hi - 0xd800) << 10) + (lo - 0xdc00), true
		}
		p.i = save
	}
	return hi, true
}

@(private)
r_property :: proc(p: ^Rparser, neg: bool) -> (Class_Item, bool) {
	if peek(p) != '{' {
		return {}, false
	}
	p.i += 1
	start := p.i
	for p.i < len(p.src) && p.src[p.i] != '}' {
		p.i += 1
	}
	if p.i >= len(p.src) {
		return {}, false
	}
	name := utf8.runes_to_string(p.src[start:p.i], context.temp_allocator)
	p.i += 1
	for i in 0 ..< len(name) {
		if name[i] == '=' {
			key := name[:i]
			if key == "General_Category" || key == "gc" {
				name = name[i + 1:]
				break
			}
			return {}, false
		}
	}
	pred: Pred
	switch name {
	case "L", "Letter":
		pred = .Letter
	case "Lu", "Uppercase_Letter":
		pred = .Upper
	case "Ll", "Lowercase_Letter":
		pred = .Lower
	case "Lt", "Titlecase_Letter":
		pred = .Title
	case "Lo", "Other_Letter", "Lm", "Modifier_Letter":
		pred = .Other_Letter
	case "M", "Mark", "Combining_Mark", "Mn", "Nonspacing_Mark", "Mc", "Spacing_Mark", "Me", "Enclosing_Mark":
		pred = .Mark
	case "N", "Number":
		pred = .Number
	case "Nd", "Decimal_Number", "digit":
		pred = .Decimal
	case "Nl", "Letter_Number", "No", "Other_Number":
		pred = .Other_Number
	case "P", "Punctuation", "punct", "Pc", "Connector_Punctuation", "Pd", "Dash_Punctuation", "Ps", "Open_Punctuation", "Pe", "Close_Punctuation", "Pi", "Initial_Punctuation", "Pf", "Final_Punctuation", "Po", "Other_Punctuation":
		pred = .Punct
	case "S", "Symbol", "Sm", "Math_Symbol", "Sc", "Currency_Symbol", "Sk", "Modifier_Symbol", "So", "Other_Symbol":
		pred = .Symbol
	case "Z", "Separator", "Zs", "Space_Separator", "Zl", "Line_Separator", "Zp", "Paragraph_Separator":
		pred = .Separator
	case "Cc", "Control", "cntrl":
		pred = .Control
	case "Any":
		pred = .Any
	case "ASCII":
		pred = .Ascii
	case:
		return {}, false
	}
	return Class_Item{is_p = true, pred = pred, neg_p = neg}, true
}

@(private)
r_class_escape :: proc(p: ^Rparser, in_class: bool) -> (item: Class_Item, single: rune, is_single: bool, ok: bool) {
	p.i += 1
	if p.i >= len(p.src) {
		return {}, 0, false, false
	}
	c := p.src[p.i]
	p.i += 1
	switch c {
	case 'd':
		return Class_Item{is_p = true, pred = .Digit}, 0, false, true
	case 'D':
		return Class_Item{is_p = true, pred = .Not_Digit}, 0, false, true
	case 'w':
		return Class_Item{is_p = true, pred = .Word}, 0, false, true
	case 'W':
		return Class_Item{is_p = true, pred = .Not_Word}, 0, false, true
	case 's':
		return Class_Item{is_p = true, pred = .Space}, 0, false, true
	case 'S':
		return Class_Item{is_p = true, pred = .Not_Space}, 0, false, true
	case 'p', 'P':
		it, pok := r_property(p, c == 'P')
		return it, 0, false, pok
	case 't':
		return {}, '\t', true, true
	case 'n':
		return {}, '\n', true, true
	case 'v':
		return {}, '\v', true, true
	case 'f':
		return {}, '\f', true, true
	case 'r':
		return {}, '\r', true, true
	case 'b':
		if in_class {
			return {}, 8, true, true
		}
		return {}, 0, false, false
	case '0':
		if p.i < len(p.src) && p.src[p.i] >= '0' && p.src[p.i] <= '9' {
			return {}, 0, false, false
		}
		return {}, 0, true, true
	case 'c':
		if p.i < len(p.src) {
			l := p.src[p.i]
			if (l >= 'a' && l <= 'z') || (l >= 'A' && l <= 'Z') {
				p.i += 1
				return {}, l % 32, true, true
			}
		}
		return {}, 0, false, false
	case 'x':
		v, hok := r_hex(p, 2)
		return {}, v, true, hok
	case 'u':
		v, uok := r_unicode_escape(p)
		return {}, v, true, uok
	case '-':
		if in_class {
			return {}, '-', true, true
		}
		return {}, 0, false, false
	case '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/':
		return {}, c, true, true
	}
	return {}, 0, false, false
}

@(private)
r_escape :: proc(p: ^Rparser) -> ^Node {
	if p.i + 1 < len(p.src) {
		c := p.src[p.i + 1]
		switch c {
		case 'b':
			p.i += 2
			return new_node(p, .Word)
		case 'B':
			p.i += 2
			return new_node(p, .Not_Word)
		case '1' ..= '9':
			p.i += 1
			g, _ := r_number(p)
			n := new_node(p, .Backref)
			n.group = g
			append(&p.refs, n)
			return n
		case 'k':
			p.i += 2
			if peek(p) != '<' {
				p.ok = false
				return new_node(p, .Empty)
			}
			p.i += 1
			start := p.i
			for p.i < len(p.src) && p.src[p.i] != '>' {
				p.i += 1
			}
			if p.i >= len(p.src) {
				p.ok = false
				return new_node(p, .Empty)
			}
			n := new_node(p, .Backref)
			n.name = utf8.runes_to_string(p.src[start:p.i], context.temp_allocator)
			p.i += 1
			append(&p.refs, n)
			return n
		}
	}
	item, single, is_single, ok := r_class_escape(p, false)
	if !ok {
		p.ok = false
		return new_node(p, .Empty)
	}
	if is_single {
		n := new_node(p, .Char)
		n.r = single
		return n
	}
	n := new_node(p, .Class)
	items := make([]Class_Item, 1, context.temp_allocator)
	items[0] = item
	n.items = items
	return n
}

@(private)
r_class :: proc(p: ^Rparser) -> ^Node {
	p.i += 1
	n := new_node(p, .Class)
	if peek(p) == '^' {
		n.neg = true
		p.i += 1
	}
	items := make([dynamic]Class_Item, context.temp_allocator)
	for p.i < len(p.src) && p.src[p.i] != ']' {
		lo: rune
		lo_single := true
		if p.src[p.i] == '\\' {
			it, s, is_s, ok := r_class_escape(p, true)
			if !ok {
				p.ok = false
				return n
			}
			if !is_s {
				append(&items, it)
				lo_single = false
			} else {
				lo = s
			}
		} else {
			lo = p.src[p.i]
			p.i += 1
		}
		if !lo_single {
			continue
		}
		if peek(p) == '-' && p.i + 1 < len(p.src) && p.src[p.i + 1] != ']' {
			p.i += 1
			hi: rune
			if p.src[p.i] == '\\' {
				_, s, is_s, ok := r_class_escape(p, true)
				if !ok || !is_s {
					p.ok = false
					return n
				}
				hi = s
			} else {
				hi = p.src[p.i]
				p.i += 1
			}
			if hi < lo {
				p.ok = false
				return n
			}
			append(&items, Class_Item{lo = lo, hi = hi})
		} else {
			append(&items, Class_Item{lo = lo, hi = lo})
		}
	}
	if p.i >= len(p.src) {
		p.ok = false
		return n
	}
	p.i += 1
	n.items = items[:]
	return n
}

@(private)
Rcomp :: struct {
	prog:  [dynamic]Inst,
	subs:  [dynamic][]Inst,
	slots: int,
	big:   bool,
}

@(private)
ok_size :: proc(c: ^Rcomp) -> bool {
	return !c.big && len(c.prog) < 1 << 20
}

@(private)
emit :: proc(c: ^Rcomp, ins: Inst) -> int {
	append(&c.prog, ins)
	if len(c.prog) > 1 << 20 {
		c.big = true
	}
	return len(c.prog) - 1
}

@(private)
emit_node :: proc(c: ^Rcomp, n: ^Node) {
	if c.big {
		return
	}
	switch n.kind {
	case .Empty:
	case .Char:
		emit(c, Inst{op = .Char, r = n.r})
	case .Any:
		emit(c, Inst{op = .Any})
	case .Class:
		emit(c, Inst{op = n.neg ? .Not_Class : .Class, items = n.items})
	case .Concat:
		for k in n.kids {
			emit_node(c, k)
		}
	case .Alt:
		jumps := make([dynamic]int, context.temp_allocator)
		for k, i in n.kids {
			if i < len(n.kids) - 1 {
				split := emit(c, Inst{op = .Split})
				c.prog[split].x = len(c.prog)
				emit_node(c, k)
				append(&jumps, emit(c, Inst{op = .Jmp}))
				c.prog[split].y = len(c.prog)
			} else {
				emit_node(c, k)
			}
		}
		for j in jumps {
			c.prog[j].x = len(c.prog)
		}
	case .Group:
		emit(c, Inst{op = .Save, x = 2 * n.group})
		emit_node(c, n.kids[0])
		emit(c, Inst{op = .Save, x = 2 * n.group + 1})
	case .Bol:
		emit(c, Inst{op = .Bol})
	case .Eol:
		emit(c, Inst{op = .Eol})
	case .Word:
		emit(c, Inst{op = .Word})
	case .Not_Word:
		emit(c, Inst{op = .Not_Word})
	case .Backref:
		emit(c, Inst{op = .Backref, x = n.group})
	case .Look:
		sub := Rcomp {
			prog = make([dynamic]Inst, context.temp_allocator),
			subs = c.subs,
		}
		sub.slots = c.slots
		emit_node(&sub, n.kids[0])
		append(&sub.prog, Inst{op = .Match})
		c.subs = sub.subs
		c.slots = sub.slots
		c.big ||= sub.big
		append(&c.subs, sub.prog[:])
		emit(c, Inst{op = .Look, x = len(c.subs) - 1, neg = n.neg, behind = n.behind})
	case .Repeat:
		k := n.kids[0]
		for _ in 0 ..< min(n.min, REGEX_MAX_REPEAT) {
			emit_node(c, k)
		}
		if n.min > REGEX_MAX_REPEAT || (n.max > REGEX_MAX_REPEAT) {
			c.big = true
			return
		}
		if n.max < 0 {
			slot := c.slots
			c.slots += 1
			loop := emit(c, Inst{op = .Split})
			body := emit(c, Inst{op = .Mark, x = slot})
			emit_node(c, k)
			emit(c, Inst{op = .Check, x = slot})
			emit(c, Inst{op = .Jmp, x = loop})
			done := len(c.prog)
			if n.greedy {
				c.prog[loop].x = body
				c.prog[loop].y = done
			} else {
				c.prog[loop].x = done
				c.prog[loop].y = body
			}
		} else {
			ends := make([dynamic]int, context.temp_allocator)
			for _ in n.min ..< n.max {
				split := emit(c, Inst{op = .Split})
				append(&ends, split)
				c.prog[split].x = len(c.prog)
				emit_node(c, k)
			}
			done := len(c.prog)
			for s in ends {
				if n.greedy {
					c.prog[s].y = done
				} else {
					c.prog[s].y = c.prog[s].x
					c.prog[s].x = done
				}
			}
		}
	}
}

@(private)
is_word :: proc "contextless" (r: rune) -> bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_'
}

@(private)
is_es_space :: proc "contextless" (r: rune) -> bool {
	switch r {
	case '\t', '\n', '\v', '\f', '\r', ' ', 0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff:
		return true
	}
	return r >= 0x2000 && r <= 0x200a
}

@(private)
pred_ok :: proc(p: Pred, r: rune) -> bool {
	switch p {
	case .Digit:
		return r >= '0' && r <= '9'
	case .Not_Digit:
		return !(r >= '0' && r <= '9')
	case .Word:
		return is_word(r)
	case .Not_Word:
		return !is_word(r)
	case .Space:
		return is_es_space(r)
	case .Not_Space:
		return !is_es_space(r)
	case .Letter:
		return unicode.is_letter(r)
	case .Upper:
		return unicode.is_upper(r)
	case .Lower:
		return unicode.is_lower(r)
	case .Title:
		return unicode.is_title(r)
	case .Other_Letter:
		return unicode.is_letter(r) && !unicode.is_upper(r) && !unicode.is_lower(r) && !unicode.is_title(r)
	case .Mark:
		return unicode.is_nonspacing_mark(r) || unicode.is_spacing_mark(r) || unicode.is_enclosing_mark(r)
	case .Number:
		return unicode.is_number(r)
	case .Decimal:
		return unicode.is_digit(r)
	case .Other_Number:
		return unicode.is_number(r) && !unicode.is_digit(r)
	case .Punct:
		return unicode.is_punct(r)
	case .Symbol:
		return unicode.is_symbol(r)
	case .Separator:
		return r == ' ' || r == 0xa0 || r == 0x1680 || (r >= 0x2000 && r <= 0x200a) || r == 0x2028 || r == 0x2029 || r == 0x202f || r == 0x205f || r == 0x3000
	case .Control:
		return unicode.is_control(r)
	case .Any:
		return true
	case .Ascii:
		return r < 128
	}
	return false
}

@(private)
class_ok :: proc(items: []Class_Item, r: rune) -> bool {
	for it in items {
		if it.is_p {
			if pred_ok(it.pred, r) != it.neg_p {
				return true
			}
		} else if r >= it.lo && r <= it.hi {
			return true
		}
	}
	return false
}

@(private)
Frame :: struct {
	pc:   int,
	sp:   int,
	slot: int,
	old:  int,
}

@(private)
Vm :: struct {
	rx:    ^Regex,
	s:     []rune,
	caps:  []int,
	marks: []int,
	steps: int,
	over:  bool,
	end:   int,
}

regex_search :: proc(rx: ^Regex, text: string) -> Regex_Result {
	runes := make([dynamic]rune, 0, len(text), context.temp_allocator)
	for r in text {
		append(&runes, r)
	}
	vm := Vm {
		rx    = rx,
		s     = runes[:],
		caps  = make([]int, 2 * (rx.groups + 1), context.temp_allocator),
		marks = make([]int, max(rx.slots, 1), context.temp_allocator),
		end   = -1,
	}
	for start in 0 ..= len(runes) {
		for i in 0 ..< len(vm.caps) {
			vm.caps[i] = -1
		}
		if _, ok := run(&vm, rx.prog, start); ok {
			return .Match
		}
		if vm.over {
			return .Too_Complex
		}
	}
	return .No_Match
}

@(private)
run :: proc(vm: ^Vm, prog: []Inst, start: int) -> (int, bool) {
	stack := make([dynamic]Frame, context.temp_allocator)
	pc := 0
	sp := start
	for {
		vm.steps += 1
		if vm.steps > REGEX_STEP_LIMIT {
			vm.over = true
			return 0, false
		}
		ins := &prog[pc]
		fail := false
		switch ins.op {
		case .Match:
			if vm.end < 0 || sp == vm.end {
				return sp, true
			}
			fail = true
		case .Char:
			if sp < len(vm.s) && vm.s[sp] == ins.r {
				sp += 1
				pc += 1
			} else {
				fail = true
			}
		case .Any:
			if sp < len(vm.s) && vm.s[sp] != '\n' && vm.s[sp] != '\r' && vm.s[sp] != 0x2028 && vm.s[sp] != 0x2029 {
				sp += 1
				pc += 1
			} else {
				fail = true
			}
		case .Class, .Not_Class:
			if sp < len(vm.s) && class_ok(ins.items, vm.s[sp]) == (ins.op == .Class) {
				sp += 1
				pc += 1
			} else {
				fail = true
			}
		case .Split:
			append(&stack, Frame{pc = ins.y, sp = sp, slot = -1})
			pc = ins.x
		case .Jmp:
			pc = ins.x
		case .Save:
			append(&stack, Frame{pc = -1, slot = ins.x, old = vm.caps[ins.x]})
			vm.caps[ins.x] = sp
			pc += 1
		case .Mark:
			append(&stack, Frame{pc = -2, slot = ins.x, old = vm.marks[ins.x]})
			vm.marks[ins.x] = sp
			pc += 1
		case .Check:
			if vm.marks[ins.x] == sp {
				fail = true
			} else {
				pc += 1
			}
		case .Bol:
			if sp == 0 {
				pc += 1
			} else {
				fail = true
			}
		case .Eol:
			if sp == len(vm.s) {
				pc += 1
			} else {
				fail = true
			}
		case .Word, .Not_Word:
			a := sp > 0 && is_word(vm.s[sp - 1])
			b := sp < len(vm.s) && is_word(vm.s[sp])
			if (a != b) == (ins.op == .Word) {
				pc += 1
			} else {
				fail = true
			}
		case .Backref:
			s0 := vm.caps[2 * ins.x]
			s1 := vm.caps[2 * ins.x + 1]
			if s0 < 0 || s1 < 0 {
				pc += 1
			} else {
				n := s1 - s0
				if sp + n <= len(vm.s) {
					same := true
					for k in 0 ..< n {
						if vm.s[s0 + k] != vm.s[sp + k] {
							same = false
							break
						}
					}
					if same {
						sp += n
						pc += 1
					} else {
						fail = true
					}
				} else {
					fail = true
				}
			}
		case .Look:
			sub := vm.rx.subs[ins.x]
			saved := make([]int, len(vm.caps), context.temp_allocator)
			copy(saved, vm.caps)
			hit := false
			saved_end := vm.end
			if ins.behind {
				vm.end = sp
				for j := sp; j >= 0 && !hit; j -= 1 {
					_, hit = run(vm, sub, j)
					if vm.over {
						return 0, false
					}
				}
			} else {
				vm.end = -1
				_, hit = run(vm, sub, sp)
				if vm.over {
					return 0, false
				}
			}
			vm.end = saved_end
			if hit != ins.neg {
				if ins.neg {
					copy(vm.caps, saved)
				}
				pc += 1
			} else {
				copy(vm.caps, saved)
				fail = true
			}
		}
		if !fail {
			continue
		}
		resumed := false
		for len(stack) > 0 {
			f := pop(&stack)
			switch f.pc {
			case -1:
				vm.caps[f.slot] = f.old
			case -2:
				vm.marks[f.slot] = f.old
			case:
				pc = f.pc
				sp = f.sp
				resumed = true
			}
			if resumed {
				break
			}
		}
		if !resumed {
			return 0, false
		}
	}
}
