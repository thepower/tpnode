# =============================================================================
# verify that the programs we need to run are installed on this system
# =============================================================================
ERL = $(shell which erl)
SED = $(shell which sed)
CT_RUN = $(shell which ct_run)
RM = $(shell which rm)
MKDIR = $(shell which mkdir)
TESTNET=./bin/testnet.sh

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
	$(TESTNET) start

lint: rebar
	$(REBAR) elvis

dialyzer: rebar
	$(REBAR) dialyzer

xref: rebar
	$(REBAR) xref skip_deps=true

tests: rebar
	$(TESTNET) start
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
#	$(TESTNET) stop

cleantest:
	$(RM) -rf _build/test
	@$(MKDIR) -p _build/test/cover
	@$(MKDIR) -p $(LOG_DIR)

buildtest: rebar
	@REBAR_PROFILE=test $(REBAR) do compile

prepare_cover: sedcheck
	@$(SED) -re "s/@[^']+/@`hostname -s`/gi" <test/tpnode.coverspec.tpl >test/tpnode.coverspec

eunit: rebar prepare_cover
	@REBAR_PROFILE=test $(REBAR) do eunit --cover

cover: ctruncheck cleantest buildtest rebar prepare_cover eunit
	@$(TESTNET) start
	@$(CT_RUN) -pa _build/test/lib/*/ebin \
	 		  -cover test/tpnode.coverspec \
	 		  -logdir $(LOG_DIR) \
	 		  -cover_stop false \
	 		  -suite basic_SUITE \
	 		  -noshell
	@$(TESTNET) stop

nocover: ctruncheck cleantest buildtest rebar
	@$(TESTNET) start
	@$(CT_RUN) -pa _build/test/lib/*/ebin \
	 		  -logdir $(LOG_DIR) \
	 		  -cover_stop false \
	 		  -suite basic_SUITE \
	 		  -noshell
	@$(TESTNET) stop

reset: cleantest
	@$(TESTNET) reset


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
