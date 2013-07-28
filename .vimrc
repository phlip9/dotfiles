set nocompatible                " needed for cool vim stuff I guess
set background=dark             " dark background
filetype off

" Vundle Setup
set rtp+=~/.vim/bundle/vundle/
call vundle#rc()

" let Vundle manage Vundle
" required!
Bundle 'gmarik/vundle'

" Other bundles
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
Bundle 'yuratomo/gmail.vim'

" filetype
filetype plugin indent on       " detect filetypes
syntax on                       " syntax highlighting

" gmail.vim Settings "
let &path = $PATH
let g:gmail_imap = 'imap.gmail.com:993'
let g:gmail_smtp = 'smtp.gmail.com:465'
let g:gmail_page_size = 50

" Two factor authentication. Don't want my password publicly available in my
" vimrc.
source ~/.gmail.vim

" Mini Buffer Explorer Settings
let g:miniBufExplMapWindowNavVim = 1
let g:miniBufExplMapWindowNavArrows = 1
let g:miniBufExplMapCTabSwitchBufs = 1
let g:miniBufExplModSelTarget = 1
set hidden                      " change buffers w/o having to write first

" Manually remapping b/c python-mode is being annoying
"nnoremap <leader>rg :RopeGotoDefinition<CR>
"nnoremap <leader>rd :RopeShowDoc<CR>
"nnoremap <leader>rf :RopeFindOccurrences<CR>
"nnoremap <leader>rm :emenu Rope . <TAB>

" ===================== "

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

set cursorline                  " show a line under the cursor
hi CursorLine cterm=none ctermbg=Black 

if has('cmdline_info')
    set ruler                                           " show rulerz
    set rulerformat=%30(%=\:b%n%y%m%r%w\ %l,%c%V\ %P%)  " uber ruler
    set showcmd                                         " show partial commands in status line
endif

" status line stuff
" powerline
set rtp+=/usr/local/lib/python2.7/dist-packages/Powerline-beta-py2.7.egg/powerline/bindings/vim
if has('statusline')
    set ambiwidth=single
    set laststatus=2
    set statusline=%<%f\        
    set statusline+=%w%h%m%r    
    set statusline+=%{fugitive#statusline()} " shmexy git status from fugitive
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
