" ignore linux kernel and module files
set wildignore+=*.ko,*.mod.c,*.order,modules.builtin

setlocal tabstop=2
setlocal shiftwidth=2
setlocal softtabstop=2
setlocal textwidth=80
setlocal smarttab
setlocal expandtab

setlocal cindent
setlocal formatoptions=tcqlron
setlocal cinoptions=l1,t0,g0

" define some common kernel macros and types
" as syntax for the fancy colors
syn keyword cOperator likely unlikely
syn keyword cType u8 u16 u32 u64 s8 s16 s32 s64

" highlight style guide violations
highlight default link LinuxError ErrorMsg

syn match LinuxError / \+\ze\t/     " spaces before tab
syn match LinuxError /\s\+$/        " trailing whitespaces
syn match LinuxError /\%81v.\+/     " virtual column 81 and more
