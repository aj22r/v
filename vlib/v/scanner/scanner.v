// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module scanner

import (
	os
	v.token
	v.pref
	v.util
)

const (
	single_quote = `\'`
	double_quote = `"`
	//is_fmt = os.getenv('VEXE').contains('vfmt')
	is_fmt = os.executable().contains('vfmt')
	num_sep = `_` // char used as number separator
)

pub struct Scanner {
mut:
	file_path                   string
	text                        string
	pos                         int
	line_nr                     int
	last_nl_pos                 int // for calculating column
	is_inside_string            bool
	is_inter_start              bool // for hacky string interpolation TODO simplify
	is_inter_end                bool
	is_debug                    bool
	line_comment                string
	// prev_tok                 TokenKind
	is_started                  bool
	fn_name                     string // needed for @FN
	is_print_line_on_error      bool
	is_print_colored_error      bool
	is_print_rel_paths_on_error bool
	quote                       byte // which quote is used to denote current string: ' or "
	line_ends                   []int // the positions of source lines ends   (i.e. \n signs)
	nr_lines                    int // total number of lines in the source file that were scanned
	is_vh                       bool // Keep newlines
	is_fmt                      bool // Used only for skipping ${} in strings, since we need literal
	// string values when generating formatted code.
	comments_mode               CommentsMode
}

pub enum CommentsMode {
	skip_comments
	parse_comments
}

// new scanner from file.
pub fn new_scanner_file(file_path string, comments_mode CommentsMode) &Scanner {
	if !os.exists(file_path) {
		verror("$file_path doesn't exist")
	}
	raw_text := util.read_file( file_path ) or {
		verror(err)
		return 0
	}
	mut s := new_scanner(raw_text, comments_mode) // .skip_comments)
	// s.init_fmt()
	s.file_path = file_path
	return s
}

// new scanner from string.
pub fn new_scanner(text string, comments_mode CommentsMode) &Scanner {
	return &Scanner{
		text: text
		is_print_line_on_error: true
		is_print_colored_error: true
		is_print_rel_paths_on_error: true
		is_fmt: is_fmt
		comments_mode: comments_mode
	}
}

fn (s &Scanner) new_token(tok_kind token.Kind, lit string) token.Token {
	return token.Token{
		kind: tok_kind
		lit: lit
		line_nr: s.line_nr + 1
		pos: s.pos
	}
}

fn (s mut Scanner) ident_name() string {
	start := s.pos
	s.pos++
	for s.pos < s.text.len && (is_name_char(s.text[s.pos]) || s.text[s.pos].is_digit()) {
		s.pos++
	}
	name := s.text[start..s.pos]
	s.pos--
	return name
}

fn filter_num_sep(txt byteptr, start int, end int) string {
	unsafe{
		mut b := malloc(end - start + 1) // add a byte for the endstring 0
		mut i := start
		mut i1 := 0
		for i < end {
			if txt[i] != num_sep {
				b[i1] = txt[i]
				i1++
			}
			i++
		}
		b[i1] = 0 // C string compatibility
		return string(b,i1)
	}
}

fn (s mut Scanner) ident_bin_number() string {
	mut has_wrong_digit := false
	mut first_wrong_digit := `\0`
	start_pos := s.pos
	s.pos += 2 // skip '0b'
	for s.pos < s.text.len {
		c := s.text[s.pos]
		if !c.is_bin_digit() && c != num_sep {
			if (!c.is_digit() && !c.is_letter()) || s.is_inside_string {
				break
			}
			else if !has_wrong_digit {
				has_wrong_digit = true
				first_wrong_digit = c
			}
		}
		s.pos++
	}
	if start_pos + 2 == s.pos {
		s.error('number part of this binary is not provided')
	}
	else if has_wrong_digit {
		s.error('this binary number has unsuitable digit `${first_wrong_digit.str()}`')
	}
	number := filter_num_sep(s.text.str, start_pos, s.pos)
	s.pos--
	return number
}

fn (s mut Scanner) ident_hex_number() string {
	mut has_wrong_digit := false
	mut first_wrong_digit := `\0`
	start_pos := s.pos
	s.pos += 2 // skip '0x'
	for s.pos < s.text.len {
		c := s.text[s.pos]
		if !c.is_hex_digit() && c != num_sep {
			if !c.is_letter() || s.is_inside_string {
				break
			}
			else if !has_wrong_digit {
				has_wrong_digit = true
				first_wrong_digit = c
			}
		}
		s.pos++
	}
	if start_pos + 2 == s.pos {
		s.error('number part of this hexadecimal is not provided')
	}
	else if has_wrong_digit {
		s.error('this hexadecimal number has unsuitable digit `${first_wrong_digit.str()}`')
	}
	number := filter_num_sep(s.text.str, start_pos, s.pos)
	s.pos--
	return number
}

fn (s mut Scanner) ident_oct_number() string {
	mut has_wrong_digit := false
	mut first_wrong_digit := `\0`
	start_pos := s.pos
	s.pos += 2 // skip '0o'
	for s.pos < s.text.len {
		c := s.text[s.pos]
		if !c.is_oct_digit() && c != num_sep {
			if (!c.is_digit() && !c.is_letter()) || s.is_inside_string {
				break
			}
			else if !has_wrong_digit {
				has_wrong_digit = true
				first_wrong_digit = c
			}
		}
		s.pos++
	}
	if start_pos + 2 == s.pos {
		s.error('number part of this octal is not provided')
	}
	else if has_wrong_digit {
		s.error('this octal number has unsuitable digit `${first_wrong_digit.str()}`')
	}
	number := filter_num_sep(s.text.str, start_pos, s.pos)
	s.pos--
	return number
}

fn (s mut Scanner) ident_dec_number() string {
	mut has_wrong_digit := false
	mut first_wrong_digit := `\0`
	mut call_method := false // true for, e.g., 12.str(), 12.3.str(), 12e-3.str()
	start_pos := s.pos
	// scan integer part
	for s.pos < s.text.len {
		c := s.text[s.pos]
		if !c.is_digit() && c != num_sep {
			if !c.is_letter() || c in [`e`, `E`] || s.is_inside_string {
				break
			}
			else if !has_wrong_digit {
				has_wrong_digit = true
				first_wrong_digit = c
			}
		}
		s.pos++
	}
	// e.g. 1..9
	// we just return '1' and don't scan '..9'
	if s.expect('..', s.pos) {
		number := filter_num_sep(s.text.str, start_pos, s.pos)
		s.pos--
		return number
	}
	// scan fractional part
	if s.pos < s.text.len && s.text[s.pos] == `.` {
		s.pos++
		if s.pos < s.text.len {
			if s.text[s.pos].is_digit() {
				for s.pos < s.text.len {
					c := s.text[s.pos]
					if !c.is_digit() {
						if !c.is_letter() || c in [`e`, `E`] || s.is_inside_string {
							if c == `.` && s.pos + 1 < s.text.len && !s.text[s.pos + 1].is_digit() && s.text[s.pos + 1] != `)` {
								call_method = true
							}
							break
						}
						else if !has_wrong_digit {
							has_wrong_digit = true
							first_wrong_digit = c
						}
					}
					s.pos++
				}
			}
			else if !(s.text[s.pos] in [`)`, `e`, `E`]) {
				call_method = true
				s.pos--
			}
		}
	}
	// scan exponential part
	mut has_exponential_part := false
	if s.expect('e', s.pos) || s.expect('E', s.pos) {
		s.pos++
		exp_start_pos := s.pos
		if s.pos < s.text.len && s.text[s.pos] in [`-`, `+`] {
			s.pos++
		}
		for s.pos < s.text.len {
			c := s.text[s.pos]
			if !c.is_digit() {
				if !c.is_letter() || s.is_inside_string {
					if c == `.` && s.pos + 1 < s.text.len && !s.text[s.pos + 1].is_digit() && s.text[s.pos + 1] != `)` {
						call_method = true
					}
					break
				}
				else if !has_wrong_digit {
					has_wrong_digit = true
					first_wrong_digit = c
				}
			}
			s.pos++
		}
		if exp_start_pos == s.pos {
			s.error('exponent has no digits')
		}
		has_exponential_part = true
	}
	// error check: 1.23.4, 123.e+3.4
	if s.pos < s.text.len && s.text[s.pos] == `.` && !call_method {
		if has_exponential_part {
			s.error('exponential part should be integer')
		}
		else {
			s.error('too many decimal points in number')
		}
	}
	if has_wrong_digit {
		s.error('this number has unsuitable digit `${first_wrong_digit.str()}`')
	}
	number := filter_num_sep(s.text.str, start_pos, s.pos)
	s.pos--
	return number
}

fn (s mut Scanner) ident_number() string {
	if s.expect('0b', s.pos) {
		return s.ident_bin_number()
	}
	else if s.expect('0x', s.pos) {
		return s.ident_hex_number()
	}
	else if s.expect('0o', s.pos) {
		return s.ident_oct_number()
	}
	else {
		return s.ident_dec_number()
	}
}

fn (s mut Scanner) skip_whitespace() {
	// if s.is_vh { println('vh') return }
	for s.pos < s.text.len && s.text[s.pos].is_space() {
		if is_nl(s.text[s.pos]) && s.is_vh {
			return
		}
		// Count \r\n as one line
		if is_nl(s.text[s.pos]) && !s.expect('\r\n', s.pos - 1) {
			s.inc_line_number()
		}
		s.pos++
	}
}

fn (s mut Scanner) end_of_file() token.Token {
	s.pos = s.text.len
	s.inc_line_number()
	return s.new_token(.eof, '')
}

pub fn (s mut Scanner) scan() token.Token {
	// if s.comments_mode == .parse_comments {
	// println('\nscan()')
	// }
	// if s.line_comment != '' {
	// s.fgenln('// LC "$s.line_comment"')
	// s.line_comment = ''
	// }
	if s.is_started {
		s.pos++
	}
	s.is_started = true
	if s.pos >= s.text.len {
		return s.end_of_file()
	}
	if !s.is_inside_string {
		s.skip_whitespace()
	}
	// End of $var, start next string
	if s.is_inter_end {
		if s.text[s.pos] == s.quote {
			s.is_inter_end = false
			return s.new_token(.string, '')
		}
		s.is_inter_end = false
		return s.new_token(.string, s.ident_string())
	}
	s.skip_whitespace()
	// end of file
	if s.pos >= s.text.len {
		return s.end_of_file()
	}
	// handle each char
	c := s.text[s.pos]
	nextc := if s.pos + 1 < s.text.len { s.text[s.pos + 1] } else { `\0` }

	// name or keyword
	if is_name_char(c) {
		name := s.ident_name()
		// tmp hack to detect . in ${}
		// Check if not .eof to prevent panic
		next_char := if s.pos + 1 < s.text.len { s.text[s.pos + 1] } else { `\0` }
		if token.is_key(name) {
			return s.new_token(token.key_to_token(name), '')
		}
		// 'asdf $b' => "b" is the last name in the string, dont start parsing string
		// at the next ', skip it
		if s.is_inside_string {
			if next_char == s.quote {
				s.is_inter_end = true
				s.is_inter_start = false
				s.is_inside_string = false
			}
		}
		// end of `$expr`
		// allow `'$a.b'` and `'$a.c()'`
		if s.is_inter_start && next_char != `.` && next_char != `(` {
			s.is_inter_end = true
			s.is_inter_start = false
		}
		if s.pos == 0 && next_char == ` ` {
			// If a single letter name at the start of the file, increment
			// Otherwise the scanner would be stuck at s.pos = 0
			s.pos++
		}
		return s.new_token(.name, name)
	}
	// `123`, `.123`
	else if c.is_digit() || (c == `.` && nextc.is_digit()) {
		if !s.is_inside_string {
			// In C ints with `0` prefix are octal (in V they're decimal), so discarding heading zeros is needed.
			mut start_pos := s.pos
			for start_pos < s.text.len && s.text[start_pos] == `0` {
				start_pos++
			}
			mut prefix_zero_num := start_pos - s.pos // how many prefix zeros should be jumped
			// for 0b, 0o, 0x the heading zero shouldn't be jumped
			if start_pos == s.text.len || (c == `0` && !s.text[start_pos].is_digit()) {
				prefix_zero_num--
			}
			s.pos += prefix_zero_num // jump these zeros
		}
		num := s.ident_number()
		return s.new_token(.number, num)
	}
	// Handle `'$fn()'`
	if c == `)` && s.is_inter_start {
		s.is_inter_end = true
		s.is_inter_start = false
		next_char := if s.pos + 1 < s.text.len { s.text[s.pos + 1] } else { `\0` }
		if next_char == s.quote {
			s.is_inside_string = false
		}
		return s.new_token(.rpar, '')
	}
	// all other tokens
	match c {
		`+` {
			if nextc == `+` {
				s.pos++
				return s.new_token(.inc, '')
			}
			else if nextc == `=` {
				s.pos++
				return s.new_token(.plus_assign, '')
			}
			return s.new_token(.plus, '')
		}
		`-` {
			if nextc == `-` {
				s.pos++
				return s.new_token(.dec, '')
			}
			else if nextc == `=` {
				s.pos++
				return s.new_token(.minus_assign, '')
			}
			return s.new_token(.minus, '')
		}
		`*` {
			if nextc == `=` {
				s.pos++
				return s.new_token(.mult_assign, '')
			}
			return s.new_token(.mul, '')
		}
		`^` {
			if nextc == `=` {
				s.pos++
				return s.new_token(.xor_assign, '')
			}
			return s.new_token(.xor, '')
		}
		`%` {
			if nextc == `=` {
				s.pos++
				return s.new_token(.mod_assign, '')
			}
			return s.new_token(.mod, '')
		}
		`?` {
			return s.new_token(.question, '')
		}
		single_quote, double_quote {
			return s.new_token(.string, s.ident_string())
		}
		`\`` {
			// ` // apostrophe balance comment. do not remove
			return s.new_token(.chartoken, s.ident_char())
		}
		`(` {
			return s.new_token(.lpar, '')
		}
		`)` {
			return s.new_token(.rpar, '')
		}
		`[` {
			return s.new_token(.lsbr, '')
		}
		`]` {
			return s.new_token(.rsbr, '')
		}
		`{` {
			// Skip { in `${` in strings
			if s.is_inside_string {
				return s.scan()
			}
			return s.new_token(.lcbr, '')
		}
		`$` {
			if s.is_inside_string {
				return s.new_token(.str_dollar, '')
			}
			else {
				return s.new_token(.dollar, '')
			}
		}
		`}` {
			// s = `hello $name !`
			// s = `hello ${name} !`
			if s.is_inside_string {
				s.pos++
				if s.text[s.pos] == s.quote {
					s.is_inside_string = false
					return s.new_token(.string, '')
				}
				return s.new_token(.string, s.ident_string())
			}
			else {
				return s.new_token(.rcbr, '')
			}
		}
		`&` {
			if nextc == `=` {
				s.pos++
				return s.new_token(.and_assign, '')
			}
			if nextc == `&` {
				s.pos++
				return s.new_token(.and, '')
			}
			return s.new_token(.amp, '')
		}
		`|` {
			if nextc == `|` {
				s.pos++
				return s.new_token(.logical_or, '')
			}
			if nextc == `=` {
				s.pos++
				return s.new_token(.or_assign, '')
			}
			return s.new_token(.pipe, '')
		}
		`,` {
			return s.new_token(.comma, '')
		}
		`@` {
			s.pos++
			name := s.ident_name()
			// @FN => will be substituted with the name of the current V function
			// @VEXE => will be substituted with the path to the V compiler
			// @FILE => will be substituted with the path of the V source file
			// @LINE => will be substituted with the V line number where it appears (as a string).
			// @COLUMN => will be substituted with the column where it appears (as a string).
			// @VHASH  => will be substituted with the shortened commit hash of the V compiler (as a string).
			// This allows things like this:
			// println( 'file: ' + @FILE + ' | line: ' + @LINE + ' | fn: ' + @FN)
			// ... which is useful while debugging/tracing
			if name == 'FN' {
				return s.new_token(.string, s.fn_name)
			}
			if name == 'VEXE' {
				vexe := pref.vexe_path()
				return s.new_token(.string, cescaped_path(vexe))
			}
			if name == 'FILE' {
				return s.new_token(.string, cescaped_path(os.real_path(s.file_path)))
			}
			if name == 'LINE' {
				return s.new_token(.string, (s.line_nr + 1).str())
			}
			if name == 'COLUMN' {
				return s.new_token(.string, (s.current_column()).str())
			}
			if name == 'VHASH' {
				return s.new_token(.string, util.vhash())
			}
			if !token.is_key(name) {
				s.error('@ must be used before keywords (e.g. `@type string`)')
			}
			return s.new_token(.name, name)
		}
		/*
	case `\r`:
		if nextc == `\n` {
			s.pos++
			s.last_nl_pos = s.pos
			return s.new_token(.nl, '')
		}
	 }
	case `\n`:
		s.last_nl_pos = s.pos
		return s.new_token(.nl, '')
	 }
	*/

		`.` {
			if nextc == `.` {
				s.pos++
				if s.text[s.pos + 1] == `.` {
					s.pos++
					return s.new_token(.ellipsis, '')
				}
				return s.new_token(.dotdot, '')
			}
			return s.new_token(.dot, '')
		}
		`#` {
			start := s.pos + 1
			s.ignore_line()
			if nextc == `!` {
				// treat shebang line (#!) as a comment
				s.line_comment = s.text[start + 1..s.pos].trim_space()
				// s.fgenln('// shebang line "$s.line_comment"')
				return s.scan()
			}
			hash := s.text[start..s.pos]
			return s.new_token(.hash, hash.trim_space())
		}
		`>` {
			if nextc == `=` {
				s.pos++
				return s.new_token(.ge, '')
			}
			else if nextc == `>` {
				if s.pos + 2 < s.text.len && s.text[s.pos + 2] == `=` {
					s.pos += 2
					return s.new_token(.right_shift_assign, '')
				}
				s.pos++
				return s.new_token(.right_shift, '')
			}
			else {
				return s.new_token(.gt, '')
			}
		}
		0xE2 {
			// case `≠`:
			if nextc == 0x89 && s.text[s.pos + 2] == 0xA0 {
				s.pos += 2
				return s.new_token(.ne, '')
			}
			// ⩽
			else if nextc == 0x89 && s.text[s.pos + 2] == 0xBD {
				s.pos += 2
				return s.new_token(.le, '')
			}
			// ⩾
			else if nextc == 0xA9 && s.text[s.pos + 2] == 0xBE {
				s.pos += 2
				return s.new_token(.ge, '')
			}
		}
		`<` {
			if nextc == `=` {
				s.pos++
				return s.new_token(.le, '')
			}
			else if nextc == `<` {
				if s.pos + 2 < s.text.len && s.text[s.pos + 2] == `=` {
					s.pos += 2
					return s.new_token(.left_shift_assign, '')
				}
				s.pos++
				return s.new_token(.left_shift, '')
			}
			else {
				return s.new_token(.lt, '')
			}
		}
		`=` {
			if nextc == `=` {
				s.pos++
				return s.new_token(.eq, '')
			}
			else if nextc == `>` {
				s.pos++
				return s.new_token(.arrow, '')
			}
			else {
				return s.new_token(.assign, '')
			}
		}
		`:` {
			if nextc == `=` {
				s.pos++
				return s.new_token(.decl_assign, '')
			}
			else {
				return s.new_token(.colon, '')
			}
		}
		`;` {
			return s.new_token(.semicolon, '')
		}
		`!` {
			if nextc == `=` {
				s.pos++
				return s.new_token(.ne, '')
			}
			else {
				return s.new_token(.not, '')
			}
		}
		`~` {
			return s.new_token(.bit_not, '')
		}
		`/` {
			if nextc == `=` {
				s.pos++
				return s.new_token(.div_assign, '')
			}
			if nextc == `/` {
				start := s.pos + 1
				s.ignore_line()
				s.line_comment = s.text[start + 1..s.pos]
				comment := s.line_comment.trim_space()
				if s.comments_mode == .parse_comments {
					// Find out if this comment is on its own line (for vfmt)
					mut is_separate_line_comment := true
					for j := start-2; j >= 0 && s.text[j] != `\n`; j-- {
						if !(s.text[j] in [`\t`, ` `]) {
							is_separate_line_comment = false
						}
					}
					if is_separate_line_comment {
						comment = '|' + comment
					}
					s.pos--
					// fix line_nr, \n was read, and the comment is marked
					// on the next line
					s.line_nr--
					return s.new_token(.comment, comment)
				}
				// s.fgenln('// ${s.prev_tok.str()} "$s.line_comment"')
				// Skip the comment (return the next token)
				return s.scan()
			}
			// Multiline comments
			if nextc == `*` {
				start := s.pos + 2
				mut nest_count := 1
				// Skip comment
				for nest_count > 0 {
					s.pos++
					if s.pos >= s.text.len {
						s.line_nr--
						s.error('comment not terminated')
					}
					if s.text[s.pos] == `\n` {
						s.inc_line_number()
						continue
					}
					if s.expect('/*', s.pos) {
						nest_count++
						continue
					}
					if s.expect('*/', s.pos) {
						nest_count--
					}
				}
				s.pos++
				if s.comments_mode == .parse_comments {
					comment := s.text[start..(s.pos - 1)].trim_space()
					return s.new_token(.comment, comment)
				}
				// Skip if not in fmt mode
				return s.scan()
			}
			return s.new_token(.div, '')
		}
		else {}
	}
	$if windows {
		if c == `\0` {
			return s.end_of_file()
		}
	}
	s.error('invalid character `${c.str()}`')
	return s.end_of_file()
}

fn (s &Scanner) current_column() int {
	return s.pos - s.last_nl_pos
}

fn (s Scanner) count_symbol_before(p int, sym byte) int {
	mut count := 0
	for i := p; i >= 0; i-- {
		if s.text[i] != sym {
			break
		}
		count++
	}
	return count
}

fn (s mut Scanner) ident_string() string {
	q := s.text[s.pos]
	is_quote := q == single_quote || q == double_quote
	is_raw := is_quote && s.text[s.pos - 1] == `r`
	if is_quote && !s.is_inside_string {
		s.quote = q
	}
	// if s.file_path.contains('string_test') {
	// println('\nident_string() at char=${s.text[s.pos].str()}')
	// println('linenr=$s.line_nr quote=  $qquote ${qquote.str()}')
	// }
	mut start := s.pos
	s.is_inside_string = false
	slash := `\\`
	for {
		s.pos++
		if s.pos >= s.text.len {
			break
		}
		c := s.text[s.pos]
		prevc := s.text[s.pos - 1]
		// end of string
		if c == s.quote && (prevc != slash || (prevc == slash && s.text[s.pos - 2] == slash)) {
			// handle '123\\'  slash at the end
			break
		}
		if c == `\n` {
			s.inc_line_number()
		}
		// Don't allow \0
		if c == `0` && s.pos > 2 && s.text[s.pos - 1] == slash {
			if s.pos < s.text.len - 1 && s.text[s.pos + 1].is_digit() {}
			else {
				s.error('0 character in a string literal')
			}
		}
		// Don't allow \x00
		if c == `0` && s.pos > 5 && s.expect('\\x0', s.pos - 3) {
			s.error('0 character in a string literal')
		}
		// ${var} (ignore in vfmt mode)
		if c == `{` && prevc == `$` && !is_raw && !s.is_fmt && s.count_symbol_before(s.pos - 2, slash) % 2 == 0 {
			s.is_inside_string = true
			// so that s.pos points to $ at the next step
			s.pos -= 2
			break
		}
		// $var
		if is_name_char(c) && prevc == `$` && !s.is_fmt && !is_raw && s.count_symbol_before(s.pos - 2, slash) % 2 == 0 {
			s.is_inside_string = true
			s.is_inter_start = true
			s.pos -= 2
			break
		}
	}
	mut lit := ''
	if s.text[start] == s.quote {
		start++
	}
	mut end := s.pos
	if s.is_inside_string {
		end++
	}
	if start > s.pos {}
	else {
		lit = s.text[start..end]
	}
	return lit
}

fn (s mut Scanner) ident_char() string {
	start := s.pos
	slash := `\\`
	mut len := 0
	for {
		s.pos++
		if s.pos >= s.text.len {
			break
		}
		if s.text[s.pos] != slash {
			len++
		}
		double_slash := s.expect('\\\\', s.pos - 2)
		if s.text[s.pos] == `\`` && (s.text[s.pos - 1] != slash || double_slash) {
			// ` // apostrophe balance comment. do not remove
			if double_slash {
				len++
			}
			break
		}
	}
	len--
	c := s.text[start + 1..s.pos]
	if len != 1 {
		u := c.ustring()
		if u.len != 1 {
			s.error('invalid character literal (more than one character)\n' + 'use quotes for strings, backticks for characters')
		}
	}
	if c == '\\`' {
		return '`'
	}
	// Escapes a `'` character
	return if c == "\'" { '\\' + c } else { c }
}

fn (s &Scanner) expect(want string, start_pos int) bool {
	end_pos := start_pos + want.len
	if start_pos < 0 || start_pos >= s.text.len {
		return false
	}
	if end_pos < 0 || end_pos > s.text.len {
		return false
	}
	for pos in start_pos .. end_pos {
		if s.text[pos] != want[pos - start_pos] {
			return false
		}
	}
	return true
}

fn (s mut Scanner) debug_tokens() {
	s.pos = 0
	s.is_started = false
	s.is_debug = true
	fname := s.file_path.all_after(os.path_separator)
	println('\n===DEBUG TOKENS $fname===')
	for {
		tok := s.scan()
		tok_kind := tok.kind
		lit := tok.lit
		print(tok_kind.str())
		if lit != '' {
			println(' `$lit`')
		}
		else {
			println('')
		}
		if tok_kind == .eof {
			println('============ END OF DEBUG TOKENS ==================')
			break
		}
	}
}

fn (s mut Scanner) ignore_line() {
	s.eat_to_end_of_line()
	s.inc_line_number()
}

fn (s mut Scanner) eat_to_end_of_line() {
	for s.pos < s.text.len && s.text[s.pos] != `\n` {
		s.pos++
	}
}

fn (s mut Scanner) inc_line_number() {
	s.last_nl_pos = s.pos
	s.line_nr++
	s.line_ends << s.pos
	if s.line_nr > s.nr_lines {
		s.nr_lines = s.line_nr
	}
}

fn (s Scanner) line(n int) string {
	mut res := ''
	if n >= 0 && n < s.line_ends.len {
		nline_start := if n == 0 { 0 } else { s.line_ends[n - 1] }
		nline_end := s.line_ends[n]
		if nline_start <= nline_end {
			res = s.text[nline_start..nline_end]
		}
	}
	return res.trim_right('\r\n').trim_left('\r\n')
}

[inline]
fn is_name_char(c byte) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || c == `_`
}

[inline]
fn is_nl(c byte) bool {
	return c == `\r` || c == `\n`
}

fn contains_capital(s string) bool {
	for c in s {
		if c >= `A` && c <= `Z` {
			return true
		}
	}
	return false
}

// HTTPRequest  bad
// HttpRequest  good
fn good_type_name(s string) bool {
	if s.len < 4 {
		return true
	}
	for i in 2 .. s.len {
		if s[i].is_capital() && s[i - 1].is_capital() && s[i - 2].is_capital() {
			return false
		}
	}
	return true
}

pub fn (s &Scanner) error(msg string) {
	pos := token.Position{
		line_nr: s.line_nr
		pos: s.pos
	}	 
	eprintln(util.formated_error('error', msg, s.file_path, pos))
	exit(1)
}

pub fn verror(s string) {
	util.verror('scanner error', s)
}

pub fn cescaped_path(s string) string {
	return s.replace('\\', '\\\\')
}
