#!/bin/bash

LOCATION="$HOME"

cd $LOCATION
rm -rf dotfiles
git clone https://github.com/abhimangs/dotfiles.git
cd dotfiles
chmod a+x install.sh
./install.sh
