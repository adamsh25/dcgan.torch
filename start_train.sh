#!/bin/bash
display=0 gpu=1 name=dizzy-gpu-1 continue=1 epoch=1500 epoch_save_modulo=500 DATA_ROOT=myimages dataset=folder nz=100 ndf=50 ngf=150 niter=5000 loadSize=129 fineSize=128 noise=normal th main.lua
