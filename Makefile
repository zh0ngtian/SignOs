NAME := SignOs
SCHEME := Feather
XCODEBUILD_FLAGS ?= -onlyUsePackageVersionsFromResolvedFile
PLATFORMS := iphoneos maccatalyst

TMP := $(TMPDIR)/$(NAME)
TLS_DIR ?= $(HOME)/Library/Application Support/IOSAdHocOTA/signos/local-install-tls

.PHONY: all clean deps $(PLATFORMS)

all: $(PLATFORMS)

clean:
	rm -rf $(TMP)
	rm -rf packages
	rm -rf Payload

deps:
	@test -s "$(TLS_DIR)/server.crt" -a -s "$(TLS_DIR)/server.pem" -a -s "$(TLS_DIR)/commonName.txt" || \
		{ echo 'Configure TLS_DIR with server.crt, server.pem and commonName.txt (see README).'; exit 1; }
	@! grep -q '[*]' "$(TLS_DIR)/commonName.txt" || \
		{ echo 'commonName.txt must contain a concrete hostname, not a wildcard certificate name.'; exit 1; }
	@openssl x509 -in "$(TLS_DIR)/server.crt" -noout -checkend 0
	@mkdir -p deps
	@cp "$(TLS_DIR)/server.crt" "$(TLS_DIR)/server.pem" "$(TLS_DIR)/commonName.txt" deps/
	@chmod 600 deps/server.crt deps/server.pem deps/commonName.txt


$(PLATFORMS): deps
	rm -rf _build

	@if [ "$@" = "iphoneos" ]; then \
		DEST="generic/platform=iOS"; \
	else \
		DEST="generic/platform=macOS,variant=Mac Catalyst"; \
	fi; \
	xcodebuild \
		-project Feather.xcodeproj \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination "$$DEST" \
		-derivedDataPath $(TMP)/$@ \
		-skipPackagePluginValidation \
		$(XCODEBUILD_FLAGS) \
		CODE_SIGNING_ALLOWED=NO \
		ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO

	mkdir -p _build/Payload
	cp -R _build/Applications/*.app _build/Payload/SignOs.app
	chmod -R 0755 _build/Payload/SignOs.app
	codesign --force --sign - --timestamp=none _build/Payload/SignOs.app
	cp deps/* _build/Payload/SignOs.app/ || true

	mkdir -p packages

	@if [ "$@" = "iphoneos" ]; then \
		ditto -c -k --sequesterRsrc --keepParent _build/Payload "packages/SignOs.ipa"; \
	else \
		ditto -c -k --sequesterRsrc --keepParent _build/Payload/SignOs.app "packages/SignOs_Catalyst.zip"; \
	fi
