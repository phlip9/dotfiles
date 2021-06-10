" movelang - VIM syntax file

syn keyword moveKeyword     module script move copy struct resource let acquires use as public mut native abort fun copyable const has friend post emits to
syn keyword moveBuiltin     move_to exists borrow_global borrow_global_mut assert move_from
syn keyword movePrimType    address u64 u8 u128 bytearray bool vector signer key store copy drop
syn keyword moveConditional if else break return
syn keyword moveLoop        while loop
syn keyword moveBool        true false
syn keyword moveSpecKeyword spec schema apply pragma verify include aborts_if ensures define with

syn keyword moveAddressDecl address  nextgroup=moveAddressLiteral skipempty skipwhite
syn keyword moveModuleDecl  module   nextgroup=moveModuleName     skipempty skipwhite
syn keyword moveResource    resource nextgroup=moveStruct         skipempty skipwhite
syn keyword moveStruct      struct   nextgroup=moveType           skipempty skipwhite
syn match moveModuleName    display "[A-Z][0-9a-zA-Z_]*"

syn keyword moveFunModifier public native nextgroup=moveFunction     skipempty skipwhite
syn keyword moveFunction    fun           nextgroup=moveFunctionName skipempty skipwhite
syn match moveFunctionName  "\%([^[:cntrl:][:space:][:punct:][:digit:]]\|_\)\%([^[:cntrl:][:punct:][:space:]]\|_\)*" display contained

syn match moveFunctionCall "\w\(\w\)*("he=e-1,me=e-1
syn match moveFunctionCall "\w\(\w\)*<"he=e-1,me=e-1

syn match moveOperator       display "\%(+\|-\|/\|*\|=\|\^\|&\||\|!\|>\|<\|%\)=\?"
syn match moveNumber         display "\<[0-9]\+\%(u\%(8\|64\|128\)\)\="
syn match moveAddressLiteral display "\<0x[0-9A-Fa-f]\+"
syn region moveBytearray     matchgroup=moveDelimiter start=+b"+ end=+"+
syn region moveHexarray      matchgroup=moveDelimiter start=+x"+ end=+"+

syn region moveCommentLine                                                  start="//"                      end="$"   contains=moveTodo,@Spell
syn region moveCommentLineDoc                                               start="//\%(//\@!\|!\)"         end="$"   contains=moveTodo,@Spell
syn region moveCommentLineDocError                                          start="//\%(//\@!\|!\)"         end="$"   contains=moveTodo,@Spell contained
syn region moveCommentBlock             matchgroup=moveCommentBlock         start="/\*\%(!\|\*[*/]\@!\)\@!" end="\*/" contains=moveTodo,moveCommentBlockNest,@Spell
syn region moveCommentBlockDoc          matchgroup=moveCommentBlockDoc      start="/\*\%(!\|\*[*/]\@!\)"    end="\*/" contains=moveTodo,moveCommentBlockDocNest,moveCommentBlockDocmoveCode,@Spell
syn region moveCommentBlockDocError     matchgroup=moveCommentBlockDocError start="/\*\%(!\|\*[*/]\@!\)"    end="\*/" contains=moveTodo,moveCommentBlockDocNestError,@Spell contained
syn region moveCommentBlockNest         matchgroup=moveCommentBlock         start="/\*"                     end="\*/" contains=moveTodo,moveCommentBlockNest,@Spell contained transparent
syn region moveCommentBlockDocNest      matchgroup=moveCommentBlockDoc      start="/\*"                     end="\*/" contains=moveTodo,moveCommentBlockDocNest,@Spell contained transparent
syn region moveCommentBlockDocNestError matchgroup=moveCommentBlockDocError start="/\*"                     end="\*/" contains=moveTodo,moveCommentBlockDocNestError,@Spell contained transparent
syn region moveAttribute                                                    start="#\["                     end="\]"

syn keyword moveTodo contained TODO FIXME XXX NB NOTE

hi def link moveStruct                 Keyword
hi def link moveResource               Keyword
hi def link moveModuleName             Identifier
hi def link moveModuleDecl             Keyword
hi def link moveAddressDecl            Keyword
hi def link moveFunModifier            Keyword
hi def link moveFunction               Keyword
hi def link moveFunctionName           Function
hi def link moveFunctionCall           Function
hi def link moveAddressLiteral         Number
hi def link moveKeyword                Keyword
hi def link moveBuiltin                Identifier
hi def link movePrimType               Type
hi def link moveConditional            Conditional
hi def link moveLoop                   Repeat
hi def link moveNumber                 Number
hi def link moveBool                   Constant
hi def link moveBytearray              String
hi def link moveHexarray               String
hi def link moveOperator               Operator
hi def link moveDelimiter              Delimiter
hi def link TodoComment                Todo
hi def link moveCommentLine            Comment
hi def link moveCommentLineDoc         SpecialComment
hi def link moveCommentLineDocLeader   moveCommentLineDoc
hi def link moveCommentLineDocError    Error
hi def link moveCommentBlock           moveCommentLine
hi def link moveCommentBlockDoc        moveCommentLineDoc
hi def link moveCommentBlockDocStar    moveCommentBlockDoc
hi def link moveCommentBlockDocError   Error
hi def link moveSpecKeyword            Keyword
hi def link moveAttribute              PreProc

let b:current_syntax = "move"
