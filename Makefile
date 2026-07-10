# Roost — Playdate build.
#
#   make         build Roost.pdx (release)
#   make run     build and open in the Playdate Simulator
#   make smoke   instrumented build -> out/RoostSmoke.pdx (autopilot + heartbeat)
#   make clean

SDK ?= $(HOME)/Developer/PlaydateSDK
PDC ?= pdc
SIMULATOR ?= $(SDK)/bin/Playdate Simulator.app
GAME := Roost

all: $(GAME).pdx

# Release: source/ already ships smokeflag.lua (SMOKE_BUILD = false), so the
# harness compiles in inert.
$(GAME).pdx: $(wildcard source/*)
	$(PDC) source $(GAME).pdx

# Smoke: stage a copy of source with the flag flipped on.
smoke: build/smoke/source
	$(PDC) build/smoke/source out/$(GAME)Smoke.pdx

build/smoke/source: $(wildcard source/*)
	mkdir -p $@ out
	cp -r source/* $@/
	echo 'SMOKE_BUILD = true' > $@/smokeflag.lua

run: $(GAME).pdx
	open -a "$(SIMULATOR)" $(GAME).pdx

clean:
	rm -rf $(GAME).pdx build out

.PHONY: all run smoke clean
