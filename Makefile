# Roost — Playdate build.
#
#   make         build Roost.pdx
#   make run     build and open in the Playdate Simulator
#   make clean

SDK ?= $(HOME)/Developer/PlaydateSDK
PDC ?= pdc
SIMULATOR ?= $(SDK)/bin/Playdate Simulator.app
GAME := Roost

all: $(GAME).pdx

$(GAME).pdx: source/main.lua source/pdxinfo
	$(PDC) source $(GAME).pdx

run: $(GAME).pdx
	open -a "$(SIMULATOR)" $(GAME).pdx

clean:
	rm -rf $(GAME).pdx

.PHONY: all run clean
