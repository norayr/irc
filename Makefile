VOC ?= voc
BUILD ?= build

.PHONY: all tests clean
all: $(BUILD)/IRC.o

$(BUILD)/IRC.o: src/IRC.Mod
	mkdir -p "$(BUILD)"
	cd "$(BUILD)" && $(VOC) -s "$(abspath src/IRC.Mod)"

$(BUILD)/irctest: src/irctest.Mod $(BUILD)/IRC.o
	cd "$(BUILD)" && $(VOC) -m "$(abspath src/irctest.Mod)"

# Build the interactive example; running it connects to the configured server.
tests: $(BUILD)/irctest

clean:
	rm -f $(addprefix $(BUILD)/,IRC.c IRC.h IRC.o IRC.sym irctest irctest.c irctest.h irctest.o irctest.sym)
