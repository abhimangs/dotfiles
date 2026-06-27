# ── PATH ──────────────────────────────────────────────────────
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/.npm-global/bin:$PATH"
export PATH="$HOME/.opencode/bin:$PATH"

### Zinit bootstrap + plugins
_zinit_zsh="$HOME/.local/share/zinit/zinit.git/zinit.zsh"
if [[ ! -f "$_zinit_zsh" ]]; then
    print -P "%F{33} %F{220}Installing %F{33}ZDHARMA-CONTINUUM%F{220} Initiative Plugin Manager (%F{33}zdharma-continuum/zinit%F{220})…%f"
    command mkdir -p "$HOME/.local/share/zinit" && command chmod g-rwX "$HOME/.local/share/zinit"
    command git clone https://github.com/zdharma-continuum/zinit "$HOME/.local/share/zinit/zinit.git" && \
        print -P "%F{33} %F{34}Installation successful.%f%b" || \
        print -P "%F{160} The clone has failed — plugins disabled.%f%b"
fi
if [[ -f "$_zinit_zsh" ]]; then
    source "$_zinit_zsh"
    autoload -Uz _zinit
    (( ${+_comps} )) && _comps[zinit]=_zinit
    zinit light-mode for \
        zdharma-continuum/zinit-annex-as-monitor \
        zdharma-continuum/zinit-annex-bin-gem-node \
        zdharma-continuum/zinit-annex-patch-dl \
        zdharma-continuum/zinit-annex-rust
    zinit light zsh-users/zsh-autosuggestions
    zinit light zdharma-continuum/fast-syntax-highlighting
    zinit light zsh-users/zsh-completions
    zinit light MichaelAquilina/zsh-you-should-use
fi
unset _zinit_zsh

# ── Completion ────────────────────────────────────────────────
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'

# ── History ───────────────────────────────────────────────────
HISTFILE=~/.zsh_history
HISTSIZE=50000
SAVEHIST=50000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE

# ── fzf ───────────────────────────────────────────────────────
[ -f /usr/share/fzf/key-bindings.zsh ] && source /usr/share/fzf/key-bindings.zsh
[ -f /usr/share/fzf/completion.zsh ]   && source /usr/share/fzf/completion.zsh

if command -v fd &>/dev/null; then
    export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
    export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
    export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
fi
export FZF_DEFAULT_OPTS=" \
--color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8 \
--color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc \
--color=marker:#b4befe,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8"

# ── Keybindings ───────────────────────────────────────────────
bindkey '^[[A' history-search-backward
bindkey '^[[B' history-search-forward
bindkey '^e'   autosuggest-accept
bindkey "^[[1;5C" forward-word
bindkey "^[[1;5D" backward-word
bindkey "^H"      backward-kill-word
bindkey "^[[3;5~" kill-word
bindkey '^T' ''
(( ${+functions[fzf-file-widget]} )) && bindkey '^F' fzf-file-widget

# ── zoxide ────────────────────────────────────────────────────
command -v zoxide &>/dev/null && eval "$(zoxide init zsh)"

# ── thefuck ───────────────────────────────────────────────────
command -v thefuck &>/dev/null && eval "$(thefuck --alias)"

# ── Aliases: Navigation ───────────────────────────────────────
alias ..='cd ..'
alias ...='cd ../..'
# Clear screen + kitty scrollback (ESC[3J erases scrollback buffer)
function clear() { command clear && printf "\033[3J"; }
alias c='clear'
alias x='exit'

# ── Aliases: eza ──────────────────────────────────────────────
if command -v eza &>/dev/null; then
    alias ls='eza --icons=always --group-directories-first'
    alias ll='eza -lah --icons=always --git --group-directories-first --time-style=relative'
    alias lt='eza --tree --icons=always --level=2'
    alias la='eza -a --icons=always --group-directories-first'
fi

# ── Aliases: Tools ────────────────────────────────────────────
if command -v bat &>/dev/null; then
    alias cat='bat'
    alias fp='fzf --preview "bat --color=always --style=numbers {}"'
fi
alias grep='grep --color=auto'
alias fkill='kill -9 $(ps aux | fzf | awk "{print \$2}")'

# ── Aliases: System ───────────────────────────────────────────
alias update='sudo pacman -Syyu && yay -Syu && flatpak update'
alias reload='source ~/.zshrc'
alias zshrc='nano ~/.zshrc'
alias myip='curl ifconfig.me'
alias ports='ss -tulpn'

# ── Aliases: Git ──────────────────────────────────────────────
alias gs='git status'
alias ga='git add .'
alias gc='git commit -m'
alias gp='git push'
alias gl='git pull'
alias lg='lazygit'
alias glog='git log --oneline --graph --decorate'

# ── Aliases: Docker ───────────────────────────────────────────
alias dps='docker ps'
alias dc='docker compose'
alias dlog='docker logs -f'
alias dex='docker exec -it'

# ── Starship ──────────────────────────────────────────────────
command -v starship &>/dev/null && eval "$(starship init zsh)"

setopt interactive_comments

alias ff='fastfetch'

# ── ProtonVPN ─────────────────────────────────────────────────
[ -f "$HOME/scripts/pvpn/pvpn.zsh" ] && source "$HOME/scripts/pvpn/pvpn.zsh"

# Kitty: reuse existing instance for near-instant startup
alias kitty='kitty --single-instance'

alias cc='claude --dangerously-skip-permissions'
alias ccr='claude --dangerously-skip-permissions --resume'
alias ccc='claude --dangerously-skip-permissions --continue'

export PATH="$HOME/.local/bin:$PATH"
alias phonecam='scrcpy --video-source=camera --camera-facing=back --camera-size=4080x3072 --video-codec=h265 --video-bit-rate=25M --max-fps=30 --v4l2-sink=/dev/video2 --no-playback'

# ── Fastfetch ─────────────────────────────────────────────────
command -v fastfetch &>/dev/null && fastfetch
