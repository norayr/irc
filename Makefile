.POSIX:

ROOTDIR  = $$PWD

all:	
	@if [ ! -d build ]; then \
		mkdir build;     \
	fi
	@cd build; voc -s ${ROOTDIR}/../src/IRC.Mod

clean:
	rm -rf build
