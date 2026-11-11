.PHONY: build test app dmg snapshots notarize clean lint

build:        ## Debug build of library + app
	swift build

test:         ## Run the CompanionCore test suite
	swift test

app:          ## Release .app in dist/ (ad-hoc signed, sandboxed)
	scripts/build-app.sh

dmg: app      ## Read-only DMG + SHA-256 in dist/
	scripts/make-dmg.sh

snapshots:    ## Offscreen renders of key screens (light/dark) in dist/snapshots
	scripts/snapshot.sh

notarize:     ## Developer ID sign + notarize + staple app and DMG (needs credentials)
	scripts/notarize.sh

clean:
	rm -rf .build dist
