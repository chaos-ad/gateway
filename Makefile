APP=gateway
REBAR ?= $(shell which rebar 2>/dev/null || which ./rebar)

.PHONY: test

all: compile

getdeps:
	git submodule init
	git submodule update
	$(REBAR) get-deps

compile: getdeps
	$(REBAR) compile

app:
	$(REBAR) compile skip_deps=true

clean:
	$(REBAR) clean
	@rm -rf erl_crash.dump

clean-app:
	$(REBAR) clean skip_deps=true
	@rm -rf erl_crash.dump

distclean: clean
	@rm -rf ebin deps logs

start:
	exec erl -pa ebin deps/*/ebin -boot start_sasl \
		-config priv/app.config \
		-config priv/extra.config \
		-name $(APP) -setcookie $(APP) \
		-s $(APP)_reloader \
		-s $(APP)

test:
	@mkdir -p .eunit
	$(REBAR) eunit skip_deps=true -v || true

dialyzer:
	dialyzer ebin deps/*/ebin -Wrace_conditions -Wunderspecs -Werror_handling

release:
	@mkdir -p /tmp/release_builder
	@rm -rf /tmp/release_builder/$(APP)
	@ln -sf $(PWD) /tmp/release_builder/$(APP)
	$(REBAR) generate force=1
	@rm -rf /tmp/release_builder/$(APP)

relclean:
	@rm -rf rel/$(APP)

ci: compile test

tag:
	@echo "Current version: $(TAG)" > DOC/CHANGELOG
	@git log --decorate  |\
         grep -E '(^ +(DOC|FIX|OPT|CHANGE|NEW|SEC|CHANGE|PERF))|tag:' |\
         sed 's/commit [0-9a-f]* (.*tag: \([0-9.]*\).*).*/\ntag: \1/'\
         >> DOC/CHANGELOG
	@git add DOC/CHANGELOG
	@git commit -m "--" DOC/CHANGELOG
	@git tag $(TAG)
