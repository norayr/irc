VOC ?= voc
BUILD ?= build
TLS_SOURCE ?= $(wildcard ../tls/src/TLS13Live.Mod)
TLS_OBJECT = $(if $(TLS_SOURCE),$(BUILD)/TLS13Live.o)

.PHONY: all tests clean
all: $(BUILD)/IRC.o $(BUILD)/IRCTCP.o $(BUILD)/IRCTLS.o

$(BUILD)/IRC.o: src/IRC.Mod
	mkdir -p "$(BUILD)"
	cd "$(BUILD)" && $(VOC) -s "$(abspath src/IRC.Mod)"

$(BUILD)/IRCTCP.o: src/IRCTCP.Mod $(BUILD)/IRC.o
	cd "$(BUILD)" && $(VOC) -s "$(abspath src/IRCTCP.Mod)"

$(BUILD)/TLS13Live.o: $(TLS_SOURCE)
	mkdir -p "$(BUILD)"
	cd "$(BUILD)" && $(VOC) -s "$(abspath $(TLS_SOURCE))"

$(BUILD)/IRCTLS.o: src/IRCTLS.Mod $(BUILD)/IRCTCP.o $(TLS_OBJECT)
	cd "$(BUILD)" && $(VOC) -s "$(abspath src/IRCTLS.Mod)"

$(BUILD)/irctest: src/irctest.Mod all
	cd "$(BUILD)" && $(VOC) -m "$(abspath src/irctest.Mod)"

$(BUILD)/TestIRC: tests/TestIRC.Mod all
	cd "$(BUILD)" && $(VOC) -m "$(abspath tests/TestIRC.Mod)"

$(BUILD)/IRCProbe: tests/IRCProbe.Mod all
	cd "$(BUILD)" && $(VOC) -m "$(abspath tests/IRCProbe.Mod)"

tests: $(BUILD)/TestIRC $(BUILD)/IRCProbe
	"$(BUILD)/TestIRC"
	python3 tests/network.py "$(abspath $(BUILD)/IRCProbe)"

.PHONY: example
example: $(BUILD)/irctest

clean:
	rm -f $(foreach module,IRC IRCTCP IRCTLS TLS13Live irctest TestIRC IRCProbe,$(addprefix $(BUILD)/$(module),.c .h .o .sym)) $(BUILD)/irctest $(BUILD)/TestIRC $(BUILD)/IRCProbe
