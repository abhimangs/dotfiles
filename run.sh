#!/bin/bash

cd $HOME
mv -f dotfiles $HOME/dotfiles_backup
git clone https://github.com/abhimangs/dotfiles.git
cd dotfiles
chmod a+x install.sh
./install.sh