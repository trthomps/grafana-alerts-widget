APP := build/Grafana Alerts.app
INSTALL_DIR ?= $(HOME)/Applications

.PHONY: app install run print clean kde-install kde-uninstall kde-test

app:
	./scripts/build-app.sh

install: app
	mkdir -p "$(INSTALL_DIR)"
	-pkill -x GrafanaAlerts
	rm -rf "$(INSTALL_DIR)/Grafana Alerts.app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/Grafana Alerts.app"
	@echo "Installed to $(INSTALL_DIR)/Grafana Alerts.app"

run: app
	-pkill -x GrafanaAlerts
	open "$(APP)"

print:
	swift run -c release GrafanaAlerts --print

clean:
	rm -rf .build build

# KDE Plasma 6 widget (see kde/README.md)
KDE_ID := dev.grafanaalerts.plasmoid

kde-install:
	kpackagetool6 -t Plasma/Applet -u kde/package 2>/dev/null || kpackagetool6 -t Plasma/Applet -i kde/package
	@echo "Installed. Add \"Grafana Alerts\" from Add Widgets. After an upgrade, restart plasmashell: systemctl --user restart plasma-plasmashell"

kde-uninstall:
	kpackagetool6 -t Plasma/Applet -r $(KDE_ID)

kde-test:
	node kde/test/grafana.test.js
