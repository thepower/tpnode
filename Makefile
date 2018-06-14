# =============================================================================
# verify that the programs we need to run are installed on this system
# =============================================================================
ERL = $(shell which erl)
SED = $(shell which sed)
CT_RUN = $(shell which ct_run)
RM = $(shell which rm)
MKDIR = $(shell which mkdir)


LOG_DIR=_build/test/logs


ifeq ($(ERL),)
$(error "Erlang not available on this system")
endif


# If there is a rebar in the current directory, use it
ifeq ($(wildcard rebar3),rebar3)
REBAR = $(CURDIR)/rebar3
endif

all:
	@echo What you wanna to make?
	@echo make build - compile
	@echo make run1 - run node1
	@echo make run2 - run node2
	@echo make run3 - rin node3

build:
	$(REBAR) compile

compile: build


deps:
	$(REBAR) get-deps


rebar:
ifeq ($(REBAR),)
$(error "rebar3 not available on this system")
endif


run1:
	erl -config app1.config -sname rocksnode1 -pa _build/default/lib/*/ebin +SDcpu 2:2: -s lager -s sync -s tpnode
run2:
	erl -config app2.config -sname rocksnode2 -pa _build/default/lib/*/ebin +SDcpu 2:2: -s lager -s sync -s tpnode
run3:
	erl -config app3.config -sname rocksnode3 -pa _build/default/lib/*/ebin +SDcpu 2:2: -s lager -s sync -s tpnode

runtestnet:
	./run_testnet.sh

lint: rebar
	$(REBAR) elvis

dialyzer: rebar
	$(REBAR) dialyzer

eunit: rebar
	$(REBAR) eunit

xref: rebar
	$(REBAR) xref skip_deps=true

tests: rebar
	./testnet.sh start
#	$(REBAR) as test ct skip_deps=true --cover --verbose
#	$(REBAR) as test ct --cover --verbose
#	mkdir -p _build/test/logs
#	cd _build/test/logs
#	$(REBAR) as test compile
#	ct_run  -logdir _build/test/logs --cover true --verbose -pa `$(REBAR) path`
	@REBAR_PROFILE=test $(REBAR) do ct --verbose
#	@REBAR_PROFILE=test $(REBAR) do ct -c, cover --verbose
#	@REBAR_PROFILE=test $(REBAR) do ct, cover --verbose
#	$(REBAR) as test cover --verbose
#	./testnet.sh stop

cleantest:
	$(RM) -rf _build/test

buildtest: rebar
	@REBAR_PROFILE=test $(REBAR) do compile

cover: sedcheck ctruncheck cleantest buildtest
	@$(SED) -re "s/@[^']+/@`hostname -s`/gi" <test/tpnode.coverspec.tpl >test/tpnode.coverspec
	@$(MKDIR) -p $(LOG_DIR)
	@./testnet.sh start
	@$(CT_RUN) -pa _build/test/lib/*/ebin \
	 		  -noshell -cover test/tpnode.coverspec \
	 		  -logdir $(LOG_DIR) \
	 		  -cover_stop false \
	 		  -verbose
	@./testnet.sh stop


sedcheck:
ifeq ($(SED),)
$(error "'sed' not available on this system")
endif

ctruncheck:
ifeq ($(CT_RUN),)
$(error "'ct_run' not available on this system")
endif


node1shell: rebar
	$(REBAR) as node1 shell
