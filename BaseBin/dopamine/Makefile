TARGET = dopamine
CC = clang

# The RootHide CLI only queries the active environment. The upstream Corellium
# installer depends on a global rootless mount and is not part of this port.
SOURCES = src/main.m ../libjailbreak/src/jbclient_xpc.c ../libjailbreak/src/jbclient_mach.c ../libjailbreak/src/jbclient_roothide.c
HEADERS = $(wildcard ../libjailbreak/src/*.h ../libjailbreak/src/roothider/*.h)
CFLAGS = -I../.include -I../libjailbreak/src -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path) -arch arm64 -miphoneos-version-min=15.0 -fblocks -Os -D BUILD_STANDALONE=$(BUILD_STANDALONE)

sign: $(TARGET)
	@ldid -Cadhoc -Sentitlements.plist $<

$(TARGET): $(SOURCES) $(HEADERS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SOURCES)

clean:
	@rm -f $(TARGET)
