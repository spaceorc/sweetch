APP_NAME   = sweetch
BUNDLE_ID  = com.spaceorc.sweetch
BUILD_DIR  = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
PLIST_SRC  = Sources/$(APP_NAME)/Info.plist

SIGN_ID    = sweetch-dev
CERT_DIR   = .cert
CERT_KEY   = $(CERT_DIR)/$(SIGN_ID).key
CERT_CRT   = $(CERT_DIR)/$(SIGN_ID).crt
CERT_P12   = $(CERT_DIR)/$(SIGN_ID).p12
CERT_CNF   = $(CERT_DIR)/$(SIGN_ID).cnf

.PHONY: all build app run debug clean setup-signing tcc-reset

all: app

# Create + import a self-signed code-signing identity into login.keychain so that
# rebuilds produce a stable designated requirement and TCC keeps the Accessibility grant.
setup-signing:
	@if security find-certificate -c "$(SIGN_ID)" >/dev/null 2>&1; then \
		echo "codesign identity '$(SIGN_ID)' already present"; \
	else \
		echo "creating self-signed identity '$(SIGN_ID)' ..."; \
		mkdir -p $(CERT_DIR); \
		printf '%s\n' \
			'[req]' \
			'distinguished_name=req_dn' \
			'x509_extensions=v3_req' \
			'prompt=no' \
			'[req_dn]' \
			'CN=$(SIGN_ID)' \
			'[v3_req]' \
			'keyUsage=critical,digitalSignature' \
			'extendedKeyUsage=critical,codeSigning' \
			'basicConstraints=critical,CA:FALSE' > $(CERT_CNF); \
		openssl genrsa -out $(CERT_KEY) 2048 2>/dev/null; \
		openssl req -new -x509 -days 3650 -key $(CERT_KEY) -out $(CERT_CRT) -config $(CERT_CNF) -extensions v3_req 2>/dev/null; \
		openssl pkcs12 -export -legacy -out $(CERT_P12) -inkey $(CERT_KEY) -in $(CERT_CRT) -name $(SIGN_ID) -password pass:sweetch 2>/dev/null; \
		security import $(CERT_P12) -k $(HOME)/Library/Keychains/login.keychain-db -P sweetch -T /usr/bin/codesign; \
		echo "done"; \
	fi

# Clear stale TCC entries that point at previous (ad-hoc) signatures.
tcc-reset:
	@tccutil reset Accessibility $(BUNDLE_ID) 2>/dev/null && echo "cleared Accessibility for $(BUNDLE_ID)" || echo "no stale Accessibility entries"

build:
	swift build -c release

app: build setup-signing
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp .build/release/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp $(PLIST_SRC) $(APP_BUNDLE)/Contents/Info.plist
	@codesign --force --sign "$(SIGN_ID)" $(APP_BUNDLE)
	@echo "built $(APP_BUNDLE)"

run: app
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@open $(APP_BUNDLE)

debug: setup-signing
	swift build -c debug
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@cp .build/debug/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp $(PLIST_SRC) $(APP_BUNDLE)/Contents/Info.plist
	@codesign --force --sign "$(SIGN_ID)" $(APP_BUNDLE)
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@open $(APP_BUNDLE)

clean:
	swift package clean
	rm -rf $(BUILD_DIR) .build
