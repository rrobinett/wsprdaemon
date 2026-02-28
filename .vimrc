" Prevent multiple sourcing
if exists("g:vimrc_loaded")
  finish
endif
let g:vimrc_loaded = 1

" Enable mouse only in normal mode, which gives you
" Click to move cursor position
" Click in different panes to switch between them
" Drag pane borders to resize
" But it won't trigger visual mode when you click and drag text - that'll go to iTerm for normal terminal selection/copy instead
set mouse=n

colorscheme industry
if has ("autocmd")
    filetype plugin indent on
endif

set expandtab
set shiftwidth=4
set softtabstop=4

set autoindent
set smartindent
set cindent

set nowrap

set term=xterm-256color
filetype plugin indent on
syntax on

if exists('$TERM_PROGRAM') && $TERM_PROGRAM == 'iTerm2'
    " Change cursor to a vertical bar in Insert mode
    let &t_SI = "\e[6 q"
    " Change cursor to a block in Normal mode
    let &t_EI = "\e[2 q"
endif
if exists('$TMUX')
    " tmux-specific cursor changes for Insert/Normal mode
    " Insert mode: vertical bar cursor
    let &t_SI = "\e[6 q"
    " Normal mode: block cursor
    let &t_EI = "\e[2 q"
endif
" F2: Horizontal split
nnoremap <F2> :split<CR>

" F3: Vertical split
nnoremap <F3> :vsplit<CR>

" F4: Increase current split size
nnoremap <F4> :resize +5<CR>
nnoremap <S-F4> :vertical resize +5<CR> " Shift+F4 for vertical resizing

" F5: Move between splits
nnoremap <F5> <C-w>w

set mouse=n
