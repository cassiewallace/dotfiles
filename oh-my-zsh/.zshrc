# ZSH Config
export ZSH="/Users/cassie/.oh-my-zsh"
ZSH_THEME="cassie"
DISABLE_UPDATE_PROMPT="true"
plugins=(git)
source $ZSH/oh-my-zsh.sh

# Virtual Environments
export WORKON_HOME=~/Envs
source /usr/local/bin/virtualenvwrapper.sh
