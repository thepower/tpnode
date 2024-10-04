#--combined-json abi,asm,ast,bin,bin-runtime,devdoc,function-debug,function-debug-runtime,generated-sources,generated-sources-runtime,hashes,metadata,opcodes,srcmap,srcmap-runtime,storage-layout,userdoc
all: build/builtinFunc.bin build/checkSig.bin build/sponsor.bin build/WETH9.bin build/ChainState.bin build/ChainState.bin-runtime build/LSTest.bin build/Caller.bin build/StorageRecursive1.bin-runtime build/multicall.bin-runtime build/ChainSettings.bin-runtime

build/builtinFunc.bin: contracts/builtinFunc.sol
	solc --abi --bin contracts/builtinFunc.sol -o build --overwrite --storage-layout

build/LSTest.bin: contracts/LSTest.sol
	solc --abi --bin contracts/LSTest.sol -o build --overwrite --storage-layout

build/checkSig.bin: contracts/check_sig.sol
	solc --abi --bin contracts/check_sig.sol -o build --overwrite --storage-layout

build/ChainState.bin-runtime: contracts/ChainState.sol
	solc --abi --bin-runtime contracts/ChainState.sol -o build --overwrite --storage-layout

build/ChainState.bin: contracts/ChainState.sol
	solc --abi --bin contracts/ChainState.sol -o build --overwrite --storage-layout

build/ChainSettings.bin-runtime: contracts/ChainSettings.sol
	solc --abi --bin-runtime contracts/ChainSettings.sol -o build --overwrite --storage-layout

build/sponsor.bin: contracts/sponsor.sol
	solc --abi --bin contracts/sponsor.sol -o build --overwrite --storage-layout

build/StorageRecursive1.bin-runtime: contracts/StorageRecursive.sol
	solc --abi --bin-runtime contracts/StorageRecursive.sol -o build --overwrite --storage-layout

build/Caller.bin: contracts/call.sol
	solc contracts/call.sol -o build --overwrite --bin-runtime --bin --no-cbor-metadata --optimize --abi

build/multicall.bin-runtime: contracts/multicall.sol
	solc contracts/multicall.sol -o build --overwrite --bin-runtime --no-cbor-metadata --optimize --abi

build/WETH9.bin: contracts/WETH9.sol
	solc --abi --bin contracts/WETH9.sol -o build --overwrite --storage-layout

all0: build/builtinFunc.json build/checkSig.json
		cat build/builtinFunc.json | jq -r .bytecode | cut -d 'x' -f 2 > build/builtinFunc.hex
		cat build/builtinFunc.json | jq -r '.abi' > build/builtinFunc.abi
		cat build/checkSig.json | jq -r .bytecode | cut -d 'x' -f 2 > build/checkSig.hex
		cat build/checkSig.json | jq -r '.abi' > build/checkSig.abi
build/builtinFunc.json: contracts/builtinFunc.sol
		truffle compile
build/checkSig.json: contracts/check_sig.sol
		truffle compile

