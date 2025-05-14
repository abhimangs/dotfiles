#!/bin/bash

LOCATION="$HOME"

cd $LOCATION
mv -f dotfiles $LOCATION/dotfiles_backup
git clone https://github.com/abhimangs/dotfiles.git
cd dotfiles
chmod a+x install.sh
./install.sh