all:
	solc --abi --bin contracts/builtinFunc.sol -o build --overwrite --storage-layout
	solc --abi --bin contracts/check_sig.sol -o build --overwrite --storage-layout

all0: build/builtinFunc.json build/checkSig.json
		cat build/builtinFunc.json | jq -r .bytecode | cut -d 'x' -f 2 > build/builtinFunc.hex
		cat build/builtinFunc.json | jq -r '.abi' > build/builtinFunc.abi
		cat build/checkSig.json | jq -r .bytecode | cut -d 'x' -f 2 > build/checkSig.hex
		cat build/checkSig.json | jq -r '.abi' > build/checkSig.abi
build/builtinFunc.json: contracts/builtinFunc.sol
		truffle compile
build/checkSig.json: contracts/check_sig.sol
		truffle compile

