" Disable these two ruby syntax items; they make the syntax highlighting
" unbearably slow.
" http://stackoverflow.com/questions/30407064/disable-specific-ruby-regex-pattern-matching-in-vim-for-performance

syntax clear rubySymbol
syntax clear rubyPredefinedConstant

" Re-enable symbol highlighting except for the slow ones.
" Syntax definitions copied from `neovim/runtime/syntax/ruby.vim`.
syn match  rubySymbol		"[]})\"':]\@<!:\%(\^\|\~\|<<\|<=>\|<=\|<\|===\|[=!]=\|[=!]\~\|!\|>>\|>=\|>\||\|-@\|-\|/\|\[]=\|\[]\|\*\*\|\*\|&\|%\|+@\|+\|`\)"
syn match  rubySymbol		"[]})\"':]\@<!:\$\%(-.\|[`~<=>_,;:!?/.'"@$*\&+0]\)"
syn match  rubySymbol		"[]})\"':]\@<!:\%(\$\|@@\=\)\=\%(\h\|[^\x00-\x7F]\)\%(\w\|[^\x00-\x7F]\)*"
syn match  rubySymbol		"[]})\"':]\@<!:\%(\h\|[^\x00-\x7F]\)\%(\w\|[^\x00-\x7F]\)*\%([?!=]>\@!\)\="
"syn match  rubySymbol		"\%([{(,]\_s*\)\@<=\l\w*[!?]\=::\@!"he=e-1
"syn match  rubySymbol		"[]})\"':]\@<!\%(\h\|[^\x00-\x7F]\)\%(\w\|[^\x00-\x7F]\)*[!?]\=:\s\@="he=e-1
syn match  rubySymbol		"\%([{(,]\_s*\)\@<=[[:space:],{]\l\w*[!?]\=::\@!"hs=s+1,he=e-1
syn match  rubySymbol		"[[:space:],{]\%(\h\|[^\x00-\x7F]\)\%(\w\|[^\x00-\x7F]\)*[!?]\=:\s\@="hs=s+1,he=e-1
syn region rubySymbol		start="[]})\"':]\@<!:'"  end="'"  skip="\\\\\|\\'"  contains=rubyQuoteEscape fold
syn region rubySymbol		start="[]})\"':]\@<!:\"" end="\"" skip="\\\\\|\\\"" contains=@rubyStringSpecial fold
