set nocompatible
set background=dark             " assume dark background

" pathogen setup stuff
runtime! autoload/pathogen.vim
silent! call pathogen#helptags()
silent! call pathogen#runtime_append_all_bundles()
silent! call pathogen#infect()

" filetype
filetype plugin indent on       " detect filetypes
syntax on                       " syntax highlighting

set mouse=a                     " enable mouse?
scriptencoding=utf-8            " set encoding to utf-8
set shortmess+=filmnrxoOtT      " abbreviate annoying messages

set history=1000                " make the history larger
" set spell                       " spell checking

" set backup                      " keep backups of files
" set undofile                    " set persistant undo (accross vim instances)
" set undolevels=1000             " # of changes that can be undone
" set undoreload=10000            " # of lines that can be undone

" color solarized

set tabpagemax=15               " max # of tabs per page
set showmode                    " show current display mode

set cursorline                  " highlight current line
hi cursorline guibg=#333333     " highlight bg color of current line
hi CursorColumn guibg=#333333   " highlight cursor

if has('cmdline_info')
    set ruler                   " show rulerz
    set rulerformat=%30(%=\:b%n%y%m%r%w\ %l,%c%V\ %P%)  " uber ruler
    set showcmd                 " show partial commands in status line
endif

" status line stuff
if has('statusline')
    set laststatus=2
    set statusline=%<%f\        
    set statusline+=%w%h%m%r    
    " set statusline+=%{fugitive#statusline()} " shmexy git status from fugitive
    set statusline+=\ [%{&ff}/%Y]   " filetype
    set statusline+=\ [%{getcwd()}] " current working directory
    set statusline+=%=%-14.(%l,%c%V%)\ %p%% " right aligned file navigation info
endif

set backspace=indent,eol,start  " easy backspace
set linespace=0                 " reduce space between lines

set nu                          " set line numbers

set showmatch                   " show matching brackets/parenthesis
set incsearch                   " find as you search
set hlsearch                    " highlight search
set ignorecase                  " ignore case
set smartcase                   " case sensitive when uc

set wildmenu                    " show list instead of just completing
set wildmode=list:longest,full  " command completion
set whichwrap=b,s,h,l,<,>,[,]   " backspace and cursor keys also wrap

set scrolljump=5                " lines to scroll when cursor leaves screen
set scrolloff=3                 " min # of lines to keep below cursor

set foldenable                  " auto fold code

set gdefault                    " always use /g on :s substitution

set nowrap                      " warp long lines

" tab rules
set autoindent                  " indent at same level as previous line
set expandtab                   " space tabs
set shiftwidth=4                " 4 spaces per tab
set softtabstop=4               " backspace deletes pseudo-tab
set tabstop=4                   " indent every 4 columns

" Remove trailing whitespaces and ^M chars
autocmd FileType c,cpp,java,php,js,python,twig,xml,yml autocmd BufWritePre <buffer> :call setline(1,map(getline(1,"$"),'substitute(v:val,"\\s\\+$","","")'))

let mapleader = ','

" run php file
autocmd FileType php noremap <F5> :w!<CR>:!php %<CR>

" php syntax check
autocmd FileType php noremap <C-L> :!php -l %<CR>

" disable arrow keys
nnoremap <up> <nop>
nnoremap <down> <nop>
nnoremap <left> <nop>
nnoremap <right> <nop>
