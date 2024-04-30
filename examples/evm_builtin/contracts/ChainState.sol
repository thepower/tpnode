// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

abstract contract getTx {
  struct tpCall {
    string func;
    uint256[] args;
  }
  struct tpSig {
    bytes raw;
    uint256 timestamp;
    bytes pubkey;
    bytes rawkey;
    bytes signature;
  }
  struct tpPayload {
    uint256 purpose;
    string cur;
    uint256 amount;
  }

  struct tpTx {
    uint256 kind;
    address from;
    address to;
    uint256 t;
    uint256 seq;
    tpCall[] call;
    tpPayload[] payload;
    tpSig[] signatures;
  }
  function get() virtual public returns (tpTx memory);
}


contract ChainState {
  struct blockSig {
    bytes node_id;
    bytes signature;
    bytes extradata;
    uint256 timestamp;
  }
  struct hashSig {
    uint256 from;
    uint256 to;
    uint256 timestamp;
  }

  uint256 public next_block_on;
  uint256 public next_report_blk;
  uint256 public epoch;
  uint256 public epoch_start_blk;
  uint256 public epoch_last_start_blk;
  uint256 public epoch_end_blk;
  uint256 public epoch_end_time;
  bool    public epoch_payed;
  bool    public self_registration;

  mapping ( bytes pubkey => uint256 ) public node_ids;
  mapping ( uint256 id => bytes ) public node_keys;
  uint256 nodes;

  bytes32[] public active_nodes;
  bytes32[] public inactive_nodes;
  bytes32[] public seed_nodes;
  
  mapping ( uint256 height => uint256 ) public block_timestamp;
  mapping ( uint256 node_id => uint256 ) public last_height;
  mapping ( uint256 node_id => mapping (uint256 => uint256) ) public attrib;
  mapping ( uint256 height => hashSig[] ) public signatures;

  event NewEpoch (uint256,uint256,uint256,uint256);
  event Blk (uint256 indexed,uint256 indexed);

  function allow_self_registration(bool allow) public {
    self_registration=allow;
  }
  function newEpoch() public {
    epoch+=1;
    epoch_last_start_blk=epoch_start_blk;
    epoch_start_blk = block.number+1;
    epoch_end_blk = epoch_start_blk+10;
    uint256 timestamp = (block.timestamp / 1000);
    epoch_end_time = timestamp+600;
    epoch_payed=false;
    emit NewEpoch(epoch_start_blk, epoch_end_blk, timestamp, epoch_end_time);
  }

  function info() public view returns (uint256 current_epoch, uint256 start_blk, uint256 end_blk,
                                       uint256 end_time,uint256 block_number){
    current_epoch=epoch;
    start_blk=epoch_start_blk;
    end_blk=epoch_end_blk;
    end_time=epoch_end_time;
    block_number=block.number;
  }

  event Sigs(uint256, bytes32, uint256, int256);
  event AB(uint256);

  function afterBlock() public returns (uint256) {
    emit AB(block.number);
    next_block_on=(block.timestamp / 1000)+90;
    if(next_report_blk<=block.number){
      next_report_blk=block.number+10;
    }
    if(block.number>=epoch_start_blk+1 && !epoch_payed){
      return _payout();
    }
    if(block.number>=epoch_end_blk){
      newEpoch();
      return 2;
    }
    return 0;
  }
  function _payout() public returns (uint256) {
    uint blkn;
    for(blkn=epoch_last_start_blk;blkn<epoch_start_blk;blkn++){
        emit Blk(blkn,signatures[blkn].length);
        uint size=signatures[blkn].length;
        if(size>0){
          uint256[] memory times=new uint256[](size);
          for(uint s_id=0;s_id<size;s_id++){
            times[s_id]=signatures[blkn][s_id].timestamp;
          }
          /*int256 m = int256(median(times));
          for(uint s_id=0;s_id<signatures[blkn].length;s_id++){
            emit Sigs(blkn,s_id,int256(signatures[blkn][s_id].timestamp)-m);
          }
           */
        }
    }
    return 1;
  }
  event Debug(uint256 indexed,uint256 indexed);
  /*
  function median(uint256[] memory data) public returns (uint256) {
    emit Debug(data.length,0);
    for(uint i = 0;i < data.length-1;i++) {
      emit Debug(i,data.length);
      uint w_min = i;
      for(uint j = i;j < data.length-1;j++) {
        if(data[j] < data[w_min]) {
          w_min = j;
        }
      }
      if(w_min == i) continue;
      uint256 tmp = data[i];
      data[i] = data[w_min];
      data[w_min] = tmp;
    }
    if(data.length % 2 == 1){
      return data[data.length / 2];
    }else{
      return (data[(data.length / 2)-1]+data[data.length / 2])/2;
    }
  }
  */
  event Debug(bytes,uint256);
  function set_attrib(uint256[2][] calldata attribs) public returns(uint256) {
    bytes memory nodekey = getTx(address(0xAFFFFFFFFF000002)).get().signatures[0].pubkey;
    uint256 slice=nodekey.length-32;
    bytes memory shortkey=_slice(nodekey,slice,32);
    uint256 nodeid=node_ids[shortkey];
    _set_attr(nodeid, attribs);
    return 1;
  }

  function _set_attr(uint256 nodeid, uint256[2][] calldata attribs) internal {
    require(nodeid>0,"unknown node");
    for(uint256 i=0;i<attribs.length;i++){
      attrib[nodeid][attribs[i][0]]=attribs[i][1];
    }
  }

  function register() public returns (uint256) {
    bytes memory nodekey = getTx(address(0xAFFFFFFFFF000002)).get().signatures[0].pubkey;
    uint256 slice=nodekey.length-32;
    bytes memory shortkey=_slice(nodekey,slice,32);
    emit Debug(nodekey,0);
    emit Debug(shortkey,1);
    if(node_ids[shortkey]==0){
      nodes++;
      node_ids[shortkey]=nodes;
      node_keys[nodes]=shortkey;
    }
    return node_ids[shortkey];
  }
  function register(bytes calldata nodekey) public returns (uint256) {
    uint256 slice=nodekey.length-32;
    if(node_ids[nodekey[slice:]]==0){
      nodes++;
      node_ids[nodekey[slice:]]=nodes;
      node_keys[nodes]=nodekey[slice:];
    }
    return node_ids[nodekey[slice:]];
  }

  function node_id(bytes calldata nodekey) public view returns (uint256) {
    uint256 slice=nodekey.length-32;
    return node_ids[nodekey[slice:]];
  }
  
  struct hSig {
    bytes pubkey;
    uint256 created;
    uint256 seen;
  }
  struct hUpd {
    bytes32 hash;
    uint256 height;
    uint256 mean_time;
    uint256 install_time;
    hSig[] sigs;
  }
  function updateData(hUpd[] calldata data) public returns (bool[] memory res) {
    bytes memory nodekey = getTx(address(0xAFFFFFFFFF000002)).get().signatures[0].rawkey;
    res=new bool[](data.length);
    for(uint i=0;i<data.length;i++){
      res[i]=_updateData(node_ids[nodekey], data[i]);
    }
  }
  function updateData(hUpd[] calldata data, uint256[2][] calldata attribs) public returns (bool[] memory res) {
    bytes memory nodekey = getTx(address(0xAFFFFFFFFF000002)).get().signatures[0].rawkey;
    uint256 nodeid=node_ids[nodekey];
    require(nodeid>0,"unknown node");
    res=new bool[](data.length);
    for(uint i=0;i<data.length;i++){
      res[i]=_updateData(nodeid, data[i]);
    }
    _set_attr(nodeid, attribs);
  }
  function node_height(bytes calldata pubkey) public view returns (uint256) {
    uint256 from=node_ids[pubkey];
    return last_height[from];
  }

  function _updateData(uint256 from, hUpd calldata data) public returns (bool) {
    if(block.number > epoch_start_blk+1)
      if(data.height<epoch_start_blk) return false;
    else
      if(data.height<epoch_last_start_blk) return false;
    uint i=0;
    for(i=0;i<data.sigs.length;i++){
      hashSig memory hs;
      hs.from = from;
      hs.to = node_ids[data.sigs[i].pubkey];
      hs.timestamp = data.sigs[i].seen;
      signatures[data.height].push(hs);
    }
    last_height[from]=data.height;
    return true;
  }


  function _slice(
        bytes memory _bytes,
        uint256 _start,
        uint256 _length
    )
        internal
        pure
        returns (bytes memory)
        {
          require(_length + 31 >= _length, "slice_overflow");
          require(_bytes.length >= _start + _length, "slice_outOfBounds");

          bytes memory tempBytes;

          assembly {
            switch iszero(_length)
            case 0 {
              // Get a location of some free memory and store it in tempBytes as
              // Solidity does for memory variables.
              tempBytes := mload(0x40)

              // The first word of the slice result is potentially a partial
              // word read from the original array. To read it, we calculate
              // the length of that partial word and start copying that many
              // bytes into the array. The first word we copy will start with
              // data we don't care about, but the last `lengthmod` bytes will
              // land at the beginning of the contents of the new array. When
              // we're done copying, we overwrite the full first word with
              // the actual length of the slice.
              let lengthmod := and(_length, 31)

              // The multiplication in the next line is necessary
              // because when slicing multiples of 32 bytes (lengthmod == 0)
              // the following copy loop was copying the origin's length
              // and then ending prematurely not copying everything it should.
              let mc := add(add(tempBytes, lengthmod), mul(0x20, iszero(lengthmod)))
              let end := add(mc, _length)

              for {
                // The multiplication in the next line has the same exact purpose
                // as the one above.
                let cc := add(add(add(_bytes, lengthmod), mul(0x20, iszero(lengthmod))), _start)
              } lt(mc, end) {
                mc := add(mc, 0x20)
                cc := add(cc, 0x20)
              } {
                mstore(mc, mload(cc))
              }

              mstore(tempBytes, _length)

              //update free-memory pointer
              //allocating the array padded to 32 bytes like the compiler does now
              mstore(0x40, and(add(mc, 31), not(31)))
            }
            //if we want a zero-length slice let's just return a zero-length array
            default {
              tempBytes := mload(0x40)
              //zero out the 32 bytes slice we are about to return
              //we need to do it because Solidity does not garbage collect
              mstore(tempBytes, 0)

              mstore(0x40, add(tempBytes, 0x20))
            }
          }

          return tempBytes;
        }
}

