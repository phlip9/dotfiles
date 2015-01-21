" ignore linux kernel and module files
set wildignore+=*.ko,*.mod.c,*.order,modules.builtin

" linux kernel style guide
" https://www.kernel.org/doc/Documentation/CodingStyle
setlocal tabstop=8
setlocal shiftwidth=8
setlocal softtabstop=8
setlocal textwidth=80
setlocal noexpandtab

setlocal cindent
setlocal formatoptions=tcqlron
setlocal cinoptions=:0,l1,t0,g0

" define some common kernel macros and types
" as syntax for the fancy colors
syn keyword cOperator likely unlikely
syn keyword cType u8 u16 u32 u64 s8 s16 s32 s64

" highlight style guide violations
highlight default link LinuxError ErrorMsg

syn match LinuxError / \+\ze\t/     " spaces before tab
syn match LinuxError /\s\+$/        " trailing whitespaces
syn match LinuxError /\%81v.\+/     " virtual column 81 and more
