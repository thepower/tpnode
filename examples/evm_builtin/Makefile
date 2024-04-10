#--combined-json abi,asm,ast,bin,bin-runtime,devdoc,function-debug,function-debug-runtime,generated-sources,generated-sources-runtime,hashes,metadata,opcodes,srcmap,srcmap-runtime,storage-layout,userdoc
all: build/builtinFunc.bin build/checkSig.bin build/sponsor.bin build/WETH9.bin build/StorageRecursive1.bin-runtime build/mcall.bin-runtime

build/builtinFunc.bin: contracts/builtinFunc.sol
	solc --abi --bin contracts/builtinFunc.sol -o build --overwrite --storage-layout

build/checkSig.bin: contracts/check_sig.sol
	solc --abi --bin contracts/check_sig.sol -o build --overwrite --storage-layout

build/sponsor.bin: contracts/sponsor.sol
	solc --abi --bin contracts/sponsor.sol -o build --overwrite --storage-layout

build/StorageRecursive1.bin-runtime: contracts/StorageRecursive.sol
	solc --abi --bin-runtime contracts/StorageRecursive.sol -o build --overwrite --storage-layout

build/mcall.bin-runtime: contracts/mcall.sol
	solc contracts/mcall.sol -o build --overwrite --bin-runtime --no-cbor-metadata --optimize --abi

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

