# =============================================================================
# verify that the programs we need to run are installed on this system
# =============================================================================
ERL = $(shell which erl)

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
	./rebar3 compile

compile: build

deps:
	./rebar3 get-deps


run1:
	erl -config app1.config -sname rocksnode1 -pa _build/default/lib/*/ebin +SDcpu 2:2: -s lager -s sync -s tpnode
run2:
	erl -config app2.config -sname rocksnode2 -pa _build/default/lib/*/ebin +SDcpu 2:2: -s lager -s sync -s tpnode
run3:
	erl -config app3.config -sname rocksnode3 -pa _build/default/lib/*/ebin +SDcpu 2:2: -s lager -s sync -s tpnode

runtestnet:
	./run_testnet.sh

lint:
	./rebar3 elvis

dialyzer:
	./rebar3 dialyzer

eunit:
	./rebar3 eunit

xref:
	./rebar3 xref skip_deps=true

tests:
	./testnet.sh start
#	./rebar3 as test ct skip_deps=true --cover --verbose
#	./rebar3 as test ct --cover --verbose
#	mkdir -p _build/test/logs
#	cd _build/test/logs
#	./rebar3 as test compile
#	ct_run  -logdir _build/test/logs --cover true --verbose -pa `./rebar3 path`
	@REBAR_PROFILE=test $(REBAR) do ct --verbose
#	@REBAR_PROFILE=test $(REBAR) do ct -c, cover --verbose
#	@REBAR_PROFILE=test $(REBAR) do ct, cover --verbose
#	./rebar3 as test cover --verbose
#	./testnet.sh stop

cover:
	ct_run -pa _build/test/lib/*/ebin -cover test/tpnode.coverspec
	#%./rebar3 as test ct --cover



node1shell:
	rebar3 as node1 shell
