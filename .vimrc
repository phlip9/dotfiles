set nocompatible                " needed for cool vim stuff I guess

" Vundle Setup
set rtp+=~/.vim/bundle/vundle/
call vundle#rc()

" let Vundle manage Vundle
" required!
Bundle 'gmarik/vundle'

" Other bundles
Bundle 'altercation/vim-colors-solarized.git'
Bundle 'kchmck/vim-coffee-script'
Bundle 'Lokaltog/vim-easymotion'
Bundle 'majutsushi/tagbar'
Bundle 'Raimondi/delimitMate'
Bundle 'scrooloose/nerdcommenter'
Bundle 'scrooloose/nerdtree'
Bundle 'scrooloose/syntastic'
Bundle 'Shougo/vimproc.vim'
Bundle 'SirVer/ultisnips'
Bundle 'sjl/gundo.vim'
Bundle 'sontek/minibufexpl.vim'
Bundle 'tpope/vim-fugitive'
Bundle 'tpope/vim-ragtag'
Bundle 'tpope/vim-surround'
Bundle 'Valloric/YouCompleteMe'
Bundle 'wincent/Command-T'
Bundle 'bling/vim-airline'

" filetype
filetype plugin indent on       " detect filetypes
syntax on                       " syntax highlighting

" colorscheme
colorscheme solarized           " solarized
set background=dark             " dark background

let g:solarized_termtrans = 1   " use terminal transparent background

" Mini Buffer Explorer Settings
let g:miniBufExplMapWindowNavVim = 1
let g:miniBufExplMapWindowNavArrows = 1
let g:miniBufExplMapCTabSwitchBufs = 1
let g:miniBufExplModSelTarget = 1
set hidden                      " change buffers w/o having to write first

" Tagbar settings
let g:tagbar_usearrows = 1
let g:tagbar_autoclose = 1      " auto close after selecting a tag
let g:tagbar_sort = 0           " don't sort

" Additional Ctags languages
" Markdown
let g:tagbar_type_markdown = {
    \ 'ctagstype' : 'markdown',
    \ 'kinds' : [
        \ 'h:Heading_L1',
        \ 'i:Heading_L2',
        \ 'k:Heading_L3'
    \ ]
\ }

" CSS
let g:tagbar_type_css = {
    \ 'ctagstype' : 'css',
    \ 'kinds' : [
        \ 'c:class',
        \ 'i:id',
        \ 't:tag',
        \ 'm:media'
    \ ]
\ }

" CoffeeScript
if executable('coffeetags')
    let g:tagbar_type_coffee = {
      \ 'ctagsbin' : 'coffeetags',
      \ 'ctagsargs' : '',
      \ 'kinds' : [
          \ 'f:functions',
          \ 'o:object',
      \ ],
      \ 'sro' : ".",
      \ 'kind2scope' : {
          \ 'f' : 'object',
          \ 'o' : 'object',
      \ }
  \ }
endif

" tags search location
set tags=./tags;~/projects;/usr/local/lib/python3.3

" NERDTree Settings
" q closes NERDTree if it is the only window open
autocmd bufenter * if (winnr("$") == 1 && exists("b:NERDTreeType") && b:NERDTreeType == "primary") | q | endif

set mouse=a                     " enable mouse
scriptencoding=utf-8            " set encoding to utf-8
set shortmess+=filmnrxoOtT      " abbreviate annoying messages

set history=1000                " make the history larger

set tabpagemax=15               " max # of tabs per page
set showmode                    " show current display mode

" use 256 colors if gnome-terminal
if $COLORTERM == 'gnome-terminal'
  set t_Co=256
endif

set cursorline                  " show a line under the cursor
hi CursorLine cterm=none ctermbg=Black 

if has('cmdline_info')
    set ruler                                           " show rulerz
    set rulerformat=%30(%=\:b%n%y%m%r%w\ %l,%c%V\ %P%)  " uber ruler
    set showcmd                                         " show partial commands in status line
endif

" status line stuff
" airline
set laststatus=2

let g:airline_powerline_fonts=1

" powerline symbols
let g:airline_symbols = {}
let g:airline_left_sep = ''
let g:airline_left_alt_sep = ''
let g:airline_right_sep = ''
let g:airline_right_alt_sep = ''
let g:airline_symbols.branch = ''
let g:airline_symbols.readonly = ''
let g:airline_symbols.linenr = ''

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
set clipboard=unnamedplus       " place yanked text into the clipboard

" tab rules
set autoindent                  " indent at same level as previous line
set expandtab                   " space tabs
set shiftwidth=4                " 4 spaces per tab
set softtabstop=4               " backspace deletes pseudo-tab
set tabstop=4                   " indent every 4 columns

" Remove trailing whitespaces and ^M chars
autocmd FileType c,cpp,java,php,js,python,twig,xml,yml autocmd BufWritePre <buffer> :call setline(1,map(getline(1,"$"),'substitute(v:val,"\\s\\+$","","")'))

let mapleader = ','

" ---------
" Functions
" ---------

" open line in browser function
function! Browser ()
    let line = getline(".")
    let line = matchstr(line, "http[^   ]*")
    exec "!google-chrome ".line
endfunction


" -----------
" Keybindings
" -----------

" disable arrow keys
nnoremap <up> <nop>
nnoremap <down> <nop>
nnoremap <left> <nop>
nnoremap <right> <nop>

" remap Visual Block selection to something that doesn't conflict with system
" copy/paste
nnoremap <leader>v <C-v>

" remap jj to escape insert mode
inoremap jj <Esc>

" open line in browser keybind
map <silent> <leader>w :call Browser ()<CR>

" map S-J and S-K to next and prev buffer
nnoremap J :bp<CR>
nnoremap K :bn<CR>

" map S-H and S-L to undo and redo
nnoremap H u
nnoremap L <C-R>

" toggle tagbar
nnoremap <leader>tb :TagbarToggle<CR>

" update tags "
nnoremap <leader>tr :!ctags -R .

" Toggle Command-T
nnoremap <leader>ct :CommandT<CR>

" Reload Vimrc
nnoremap <silent> <leader>V :source ~/.vimrc<CR>:filetype detect<CR>:exe ":echo 'vimrc reloaded'"<CR>

" Open NERDTree
nnoremap <leader>n :NERDTreeToggle<CR>

" Window movement w CTRL + J,K,L,H
nnoremap <c-j> <c-w>j
nnoremap <c-k> <c-w>k
nnoremap <c-l> <c-w>l
nnoremap <c-h> <c-w>h

" Gundo
nnoremap <leader>g :GundoToggle<CR>

" Make vim into a hex editor
nnoremap <leader>hx :%!xxd<CR>
nnoremap <leader>hr :%!xxd -r<CR>

" YouCompleteMe
let g:ycm_key_list_previous_completion=['<Up>']
let g:ycm_key_list_select_completion=['<Down>', '<Enter>']

" GoToDefinition
nnoremap <leader>jd :YcmCompleter GoToDefinitionElseDeclaration<CR>

"" Ultisnips
let g:UltiSnipsExpandTrigger="<Tab>"
let g:UltiSnipsJumpForwardTrigger="<Tab>"

nnoremap <leader><leader>u :py UltiSnips_Manager.list_snippets()<CR>
