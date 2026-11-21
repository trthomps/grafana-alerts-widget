APP := build/Grafana Alerts.app
INSTALL_DIR ?= $(HOME)/Applications

.PHONY: app install run print clean

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
