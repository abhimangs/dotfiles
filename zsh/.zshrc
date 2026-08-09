# ── PATH ──────────────────────────────────────────────────────
# Declared here so the CLI installers see their bin dir already on PATH and
# skip appending their own export block to this file (it is a stow symlink
# into ~/dotfiles — their edits would dirty the repo).
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/.npm-global/bin:$PATH"
export PATH="$HOME/.opencode/bin:$PATH"
export PATH="$HOME/.kimi-code/bin:$PATH"
export PATH="$HOME/.bun/bin:$PATH"

### Zinit bootstrap + plugins
_zinit_zsh="$HOME/.local/share/zinit/zinit.git/zinit.zsh"
# Needs git — a minimal server image may not have it, and without this guard
# every single shell start printed "command not found: git" and retried.
if [[ ! -f "$_zinit_zsh" ]] && command -v git &>/dev/null; then
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

# ── micro ─────────────────────────────────────────────────────
# Without this micro drops to 256 colours and the Catppuccin scheme in
# micro/settings.json renders as approximations of itself.
export MICRO_TRUECOLOR=1

# ── bun ───────────────────────────────────────────────────────
# Written by `bun completions`; kept here (portably) so the installer finds it
# already present and leaves this file alone.
[ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"

# ── fzf ───────────────────────────────────────────────────────
# Distros put the shell integration in different places: Arch uses
# /usr/share/fzf/, Debian and Ubuntu use /usr/share/doc/fzf/examples/.
# fzf >= 0.48 can just print it, so prefer that and keep the paths as a
# fallback for older builds.
if command -v fzf &>/dev/null; then
    if fzf --zsh >/dev/null 2>&1; then
        source <(fzf --zsh)
    else
        for _fzf_f in \
            /usr/share/fzf/key-bindings.zsh \
            /usr/share/fzf/completion.zsh \
            /usr/share/doc/fzf/examples/key-bindings.zsh \
            /usr/share/doc/fzf/examples/completion.zsh
        do
            [ -f "$_fzf_f" ] && source "$_fzf_f"
        done
        unset _fzf_f
    fi
fi

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
# Built from what is actually installed — a server with no paru or flatpak
# would otherwise fail the whole chain on the first missing command.
if command -v pacman &>/dev/null; then
    _upd='sudo pacman -Syu'
    command -v paru    &>/dev/null && _upd="$_upd && paru -Sua"
elif command -v apt &>/dev/null; then
    _upd='sudo apt update && sudo apt full-upgrade -y'
fi
if [[ -n "$_upd" ]]; then
    command -v flatpak &>/dev/null && _upd="$_upd && flatpak update"
    alias update="$_upd"
fi
unset _upd
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

alias phonecam='scrcpy --video-source=camera --camera-facing=back --camera-size=4080x3072 --video-codec=h265 --video-bit-rate=25M --max-fps=30 --v4l2-sink=/dev/video2 --no-playback'

# ── Fastfetch ─────────────────────────────────────────────────
command -v fastfetch &>/dev/null && fastfetch
