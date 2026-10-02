APP_NAME   = sweetch
BUNDLE_ID  = com.spaceorc.sweetch
BUILD_DIR  = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
PLIST_SRC  = Sources/$(APP_NAME)/Info.plist

SIGN_ID    = sweetch-dev
OPENSSL    = openssl
# OpenSSL 3 writes PKCS#12 with AES-256-CBC/PBKDF2, which Security.framework refuses
# to import; -legacy restores the RC2/3DES encoding it understands. LibreSSL — what
# /usr/bin/openssl is on macOS — already emits that format and rejects the flag.
P12_LEGACY = $(shell $(OPENSSL) pkcs12 -help 2>&1 | grep -q -- -legacy && echo -legacy)
CERT_DIR   = .cert
CERT_KEY   = $(CERT_DIR)/$(SIGN_ID).key
CERT_CRT   = $(CERT_DIR)/$(SIGN_ID).crt
CERT_P12   = $(CERT_DIR)/$(SIGN_ID).p12
CERT_CNF   = $(CERT_DIR)/$(SIGN_ID).cnf

# The icon is drawn in code (Tools/make-icon.swift) rather than checked in as a binary
# asset. The Dock reads the *bundle* icon, so it has to end up in Contents/Resources —
# setting applicationIconImage at runtime isn't picked up reliably when an accessory app
# switches to a regular activation policy.
WATCHDOG_LABEL = com.spaceorc.sweetch.watchdog
WATCHDOG_PLIST = $(HOME)/Library/LaunchAgents/$(WATCHDOG_LABEL).plist

ICON_TOOL  = Tools/make-icon.swift
ICON_ICNS  = $(BUILD_DIR)/AppIcon.icns
ICONSET    = $(BUILD_DIR)/AppIcon.iconset

.PHONY: all build app run debug clean setup-signing tcc-reset icon stop start trace

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
		$(OPENSSL) genrsa -out $(CERT_KEY) 2048 2>/dev/null; \
		$(OPENSSL) req -new -x509 -days 3650 -key $(CERT_KEY) -out $(CERT_CRT) -config $(CERT_CNF) -extensions v3_req 2>/dev/null; \
		$(OPENSSL) pkcs12 -export $(P12_LEGACY) -out $(CERT_P12) -inkey $(CERT_KEY) -in $(CERT_CRT) -name $(SIGN_ID) -password pass:sweetch; \
		security import $(CERT_P12) -k $(HOME)/Library/Keychains/login.keychain-db -P sweetch -T /usr/bin/codesign; \
		echo "done"; \
	fi

# Clear stale TCC entries that point at previous (ad-hoc) signatures.
tcc-reset:
	@tccutil reset Accessibility $(BUNDLE_ID) 2>/dev/null && echo "cleared Accessibility for $(BUNDLE_ID)" || echo "no stale Accessibility entries"

# Rebuilding swaps the executable out from under a running instance, whose signature then
# no longer matches — the kernel kills it and macOS files a crash report for something that
# never crashed. So stop it first. If the watchdog agent owns the process, the job has to be
# unloaded too, or launchd races the rebuild by restarting the old binary.
stop:
	@if [ -f $(WATCHDOG_PLIST) ]; then launchctl bootout gui/$$(id -u)/$(WATCHDOG_LABEL) 2>/dev/null || true; fi
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 0.4

start:
	@if [ -f $(WATCHDOG_PLIST) ]; then \
		launchctl bootstrap gui/$$(id -u) $(WATCHDOG_PLIST) && echo "started under the watchdog"; \
	else \
		open $(APP_BUNDLE); \
	fi

icon: $(ICON_ICNS)

$(ICON_ICNS): $(ICON_TOOL)
	@mkdir -p $(BUILD_DIR)
	@swiftc -O $(ICON_TOOL) -o $(BUILD_DIR)/make-icon
	@$(BUILD_DIR)/make-icon $(BUILD_DIR)/icon-1024.png
	@rm -rf $(ICONSET) && mkdir -p $(ICONSET)
	@sips -z 16 16     $(BUILD_DIR)/icon-1024.png --out $(ICONSET)/icon_16x16.png      >/dev/null
	@sips -z 32 32     $(BUILD_DIR)/icon-1024.png --out $(ICONSET)/icon_16x16@2x.png   >/dev/null
	@sips -z 32 32     $(BUILD_DIR)/icon-1024.png --out $(ICONSET)/icon_32x32.png      >/dev/null
	@sips -z 64 64     $(BUILD_DIR)/icon-1024.png --out $(ICONSET)/icon_32x32@2x.png   >/dev/null
	@sips -z 128 128   $(BUILD_DIR)/icon-1024.png --out $(ICONSET)/icon_128x128.png    >/dev/null
	@sips -z 256 256   $(BUILD_DIR)/icon-1024.png --out $(ICONSET)/icon_128x128@2x.png >/dev/null
	@sips -z 256 256   $(BUILD_DIR)/icon-1024.png --out $(ICONSET)/icon_256x256.png    >/dev/null
	@sips -z 512 512   $(BUILD_DIR)/icon-1024.png --out $(ICONSET)/icon_256x256@2x.png >/dev/null
	@sips -z 512 512   $(BUILD_DIR)/icon-1024.png --out $(ICONSET)/icon_512x512.png    >/dev/null
	@cp $(BUILD_DIR)/icon-1024.png $(ICONSET)/icon_512x512@2x.png
	@iconutil -c icns $(ICONSET) -o $(ICON_ICNS)
	@echo "built $(ICON_ICNS)"

build:
	swift build -c release

app: build setup-signing $(ICON_ICNS)
	@$(MAKE) --no-print-directory stop
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp .build/release/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp $(PLIST_SRC) $(APP_BUNDLE)/Contents/Info.plist
	@cp $(ICON_ICNS) $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@cp .env $(APP_BUNDLE)/Contents/Resources/sweetch.env 2>/dev/null || echo "warning: .env missing — LLM correction disabled"
	@codesign --force --sign "$(SIGN_ID)" $(APP_BUNDLE)
	@touch $(APP_BUNDLE)
	@echo "built $(APP_BUNDLE)"

run: app start

debug: setup-signing $(ICON_ICNS)
	swift build -c debug
	@$(MAKE) --no-print-directory stop
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp .build/debug/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp $(PLIST_SRC) $(APP_BUNDLE)/Contents/Info.plist
	@cp $(ICON_ICNS) $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@cp .env $(APP_BUNDLE)/Contents/Resources/sweetch.env 2>/dev/null || echo "warning: .env missing — LLM correction disabled"
	@codesign --force --sign "$(SIGN_ID)" $(APP_BUNDLE)
	@$(MAKE) --no-print-directory start

# Record what happens while you reproduce a "doesn't work in app X" problem: sweetch's own log
# plus every key event, physical (HID) and as delivered to apps (APP), with sweetch's synthetic
# ones marked. Both files use wall-clock times so they can be read side by side. Ctrl-C stops.
TRACE_DIR = $(BUILD_DIR)/trace
KEYWATCH  = $(BUILD_DIR)/keywatch

$(KEYWATCH): Tools/keywatch.swift
	@mkdir -p $(BUILD_DIR)
	@swiftc -O Tools/keywatch.swift -o $(KEYWATCH)

trace: $(KEYWATCH)
	@mkdir -p $(TRACE_DIR)
	@echo "recording to $(TRACE_DIR)/sweetch.log and $(TRACE_DIR)/keys.log — reproduce, then Ctrl-C"
	@trap 'kill 0' INT TERM; \
		/usr/bin/log stream --style compact --level debug --predicate 'subsystem == "$(BUNDLE_ID)"' > $(TRACE_DIR)/sweetch.log & \
		$(KEYWATCH) > $(TRACE_DIR)/keys.log & \
		wait

clean:
	swift package clean
	rm -rf $(BUILD_DIR) .build
