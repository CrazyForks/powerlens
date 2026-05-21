BINARY   := powerlens-fetch
SRC_DIR  := src
BIN_DIR  := bin

.PHONY: all arm64 amd64 universal install clean

all: arm64 amd64

arm64:
	cd $(SRC_DIR) && GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 \
	  go build -o ../$(BIN_DIR)/$(BINARY)-arm64 .
	codesign --sign - $(BIN_DIR)/$(BINARY)-arm64

amd64:
	cd $(SRC_DIR) && GOOS=darwin GOARCH=amd64 CGO_ENABLED=1 \
	  go build -o ../$(BIN_DIR)/$(BINARY)-amd64 .
	codesign --sign - $(BIN_DIR)/$(BINARY)-amd64

universal:
	$(MAKE) arm64 amd64
	lipo -create -output $(BIN_DIR)/$(BINARY)-universal \
	  $(BIN_DIR)/$(BINARY)-arm64 \
	  $(BIN_DIR)/$(BINARY)-amd64
	codesign --sign - $(BIN_DIR)/$(BINARY)-universal

install: arm64 amd64

clean:
	rm -f $(BIN_DIR)/$(BINARY)-arm64 $(BIN_DIR)/$(BINARY)-amd64 \
	       $(BIN_DIR)/$(BINARY)-universal
