// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "contracts/BronKerbosch.sol";
import "contracts/access/Ownable.sol";
import "contracts/GetTx.sol";
import "contracts/ChainFee.sol";
import "contracts/ChainManagement.sol";

contract ChainState is Ownable {
  enum NodeKind {
    NODE_UNKNOWN,
    NODE_SEED,
    NODE_CANDIDATE,
    NODE_CONSENSUS
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
  mapping ( uint256 id => NodeKind ) public node_kind;
  uint8 public nodes;
  uint256 public consensus_mask;
  uint8 public consensus_nodes;
  uint8 public minsig;

  mapping ( uint256 height => uint256 ) public block_timestamp;
  mapping ( uint256 node_id => uint256 ) public last_height;
  mapping ( uint256 node_id => mapping (uint256 => uint256) ) public attrib;

  mapping ( uint256 height => uint8 ) public blocknode_sigcnt;
  mapping ( uint256 height => uint256[2][] ) public blocknode_sigmask;

  mapping ( uint256 height => uint256 ) public block_clique;

  uint256 public calc_till;

  //uint256 public constant MAX_BLOCK_TIME = 3600; //1 hour - maximum block interval
  //uint256 public constant MAX_EPOCH_TIME = 3600*2; //2 hours - maximum epoch duration
  uint256 public constant MAX_BLOCK_TIME = 300; //5 min - maximum block interval
  uint256 public constant MAX_EPOCH_TIME = 300*2; //10 min - maximum epoch duration
  //uint256 public constant EPOCH_BLOCKS = 100;
  uint256 public constant EPOCH_BLOCKS = 20; //10 blocks epoch
  //uint256 public constant REPORT_BLOCKS = 10;
  uint256 public constant REPORT_BLOCKS = 10;
  uint256 public constant CALC_DELAY = REPORT_BLOCKS+2; //give 2 blocks extra time
  uint256 public constant STORE_CLIQUE_BLOCKS = 500;

  ChainFee public chainfee;
  mapping ( uint256 node_id => address ) public node_addr;
  bool public test_mode;
  ChainManagement public chainmgmt;
  mapping ( uint256 id => uint256 ) public node_stat;
  uint256 public next_mask;

  event NewEpoch (uint256,uint256,uint256,uint256);
  event Blk (uint256 indexed, uint256 indexed);

  constructor(bool _selfreg, bytes[] memory initial_nodes) Ownable(msg.sender) {
    self_registration=_selfreg;
    uint8 i=0;
    require(initial_nodes.length<16, "Start with lower amount of nodes");
    for(i=0;i<initial_nodes.length;i++){
      uint256 nodeid=_register(initial_nodes[i]);
      _update_consensus(nodeid,true);
    }
    test_mode=false;
  }
  function set_chainfee(address payable _new) public onlyOwner {
    chainfee=ChainFee(_new);
  }
  function set_chainmgmt(address _new) public onlyOwner {
    chainmgmt=ChainManagement(_new);
  }
  function set_test(bool _value) public onlyOwner {
    test_mode=_value;
  }

  function allow_self_registration(bool allow) public onlyOwner {
    self_registration=allow;
  }
  function newEpoch() public onlyOwner {
    _newEpoch();
  }
  function _newEpoch() internal {
    epoch+=1;
    epoch_last_start_blk=epoch_start_blk;
    epoch_start_blk = block.number+1;
    epoch_end_blk = epoch_start_blk+EPOCH_BLOCKS;
    uint256 ts = timestamp();
    epoch_end_time = ts+MAX_EPOCH_TIME;
    epoch_payed=false;
    emit NewEpoch(epoch_start_blk, epoch_end_blk, ts, epoch_end_time);
    if (address(chainfee) != address(0)){
      chainfee.new_epoch(epoch);
    }
    if (next_mask>0) {
      consensus_mask=next_mask;
      consensus_nodes=uint8(popcnt(consensus_mask));
      minsig=(consensus_nodes/2)+1;
      next_mask=0;
    }
  }

  function info() public view returns (uint256 current_epoch, uint256 start_blk, uint256 end_blk,
                                       uint256 end_time,uint256 block_number){
    current_epoch=epoch;
    start_blk=epoch_start_blk;
    end_blk=epoch_end_blk;
    end_time=epoch_end_time;
    block_number=block.number;
  }

  event Calc(uint256, uint256);
  event Payout(uint256 blk0, uint256 blk1, uint256 and_mask, uint256 or_mask);
  event PayoutRes(uint256 payed, uint256 burned);
  event PayOutFail(bytes);
  event RegisterNode(uint256,bytes);
  event NewMask(uint256, uint256, uint256);

  function timestamp() private view returns (uint256) {
    uint256 ts = block.timestamp;
    if( ts > 1000000000000 )  //on some legacy chains time in ms
      ts/=1000;
    return ts;
  }

  function afterBlock() public returns (uint256) {
    if(epoch==0){
      _newEpoch();
      return 2;
    }

    next_block_on=timestamp()+MAX_BLOCK_TIME;
    if(next_report_blk<=block.number){
      next_report_blk=block.number+REPORT_BLOCKS;
    }

    if(block.number>=CALC_DELAY) {
      uint256 blk=block.number-CALC_DELAY;
      uint256 mask=calc_block(blk);
      emit Calc(blk,mask);
      block_clique[blk]=mask;
      clean_block(blk);
      calc_till=block.number-CALC_DELAY;
      if(blk>STORE_CLIQUE_BLOCKS){ //cleanup after X blocks
        block_clique[blk-STORE_CLIQUE_BLOCKS]=0;
      }
    }
    if(calc_till>=epoch_start_blk && !epoch_payed){
      return _payout();
    }
    if(block.number>=epoch_end_blk){
      _newEpoch();
      return 2;
    }
    return 0;
  }

  function clean_block(uint256 number) internal returns(uint256) {
    uint256 cnt=blocknode_sigcnt[number];
    uint256 r=0;
    while(r++<cnt){
      blocknode_sigmask[number].pop();
    }
    blocknode_sigcnt[number]=0;
    return cnt;
  }
  function calc_block(uint256 number) public returns(uint256) {
    uint256 mask=BronKerbosch(address(0xAFFFFFFFFF000007))
                  .max_clique_mask(blocknode_sigmask[number]);
    return mask<<1;
  }

  function _payout() internal returns (uint256) {
    /* _payout function description:
     * 1. Iterate over all blocks in the epoch
     * 2. Calculate the OR and AND masks of all cliques in the epoch
     * 3. Calculate the number of winners and the amount of tokens to burn
     * 4. Call the chainfee contract to transfer the tokens to the winners and burn the rest
     */
    uint blkn;
    uint cc_or=consensus_mask;
    uint cc_and=0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    emit Payout(epoch_last_start_blk,epoch_start_blk-1,0,consensus_mask);
    for(blkn=epoch_last_start_blk;blkn<epoch_start_blk;blkn++){
      if(block_clique[blkn]==0)
        continue; //ignore blocks with no statistics
        emit Blk(blkn,block_clique[blkn]);
        cc_or|=block_clique[blkn];
        cc_and&=block_clique[blkn];
    }
    emit Payout(epoch_last_start_blk,epoch_start_blk-1,cc_or,cc_and);
    if (address(chainfee) != address(0)){
      //function payout(address[] calldata _payto, uint256 _toburn) public returns (uint256 payed,
      uint winners=0;
      uint burn=0;
      {
        uint cc_or1=cc_or;
        uint cc_and1=cc_and;
        //first shift, calculate the number of winners and the amount to burn
        for(uint i=0;cc_or1>0;i++){
          if(cc_or1 & 1 == 1){
            if(cc_and1 & 1 == 1){
              winners++;
            }else{
              burn++;
            }
          }
          cc_or1>>=1;
          cc_and1>>=1;
        }
      }

      address[] memory a=new address[](winners);
      {
        uint cc_or1=cc_or;
        uint cc_and1=cc_and;
        //second shift, fill the winners array, increase or decrease stat for node
        for(uint i=0;cc_or1>0;i++){
          if(cc_and1 & 1 == 1){
            winners--;
            if(attrib[i][1]>0){
              a[winners]=address(uint160(attrib[i][i]));
            }else{
              a[winners]=node_addr[i];
            }
          }
          if(cc_or1 & 1 == 1){
            if(cc_and1 & 1 == 1){
              _node_inc_stat(i);
            }else{
              _node_dec_stat(i);
            }
          }

          cc_or1>>=1;
          cc_and1>>=1;
        }
      }
      require(winners==0,"something calculated wrong");


      (bool res, bytes memory result) = address(chainfee).call(
        abi.encodeWithSignature("payout(address[],uint256)",a,burn)
      );
      if(res) {
        //(uint256 payed, uint256 burned) = chainfee.payout(a,burn);
        (uint256 payed, uint256 burned) = abi.decode(result, (uint256,uint256));

        emit PayoutRes(payed,burned);
      }else{
        emit PayOutFail(result);
      }

    }
    if (address(chainmgmt) != address(0)){
      //chainmgmt.epoch_update(consensus_mask,cc_or,cc_and);

      (bool res, bytes memory result) = address(chainmgmt).call(
        abi.encodeWithSignature("epoch_update(uint256,uint256,uint256)",
                                consensus_mask,cc_or,cc_and)
      );
      if(res) {
        (uint256 emergency_mask, uint256 new_next_mask) = abi.decode(result, (uint256, uint256));
        emit NewMask(consensus_mask,emergency_mask,new_next_mask);
        if(new_next_mask>0 && new_next_mask!=consensus_mask){
          next_mask=new_next_mask;
        }
        if(emergency_mask>0 && emergency_mask!=consensus_mask){
          consensus_mask=emergency_mask;
          consensus_nodes=uint8(popcnt(emergency_mask));
          minsig=(consensus_nodes/2)+1;
        }
      }
    }

    epoch_payed=true;
    return 1;
  }


  function set_attrib(uint256[2][] calldata attribs) public returns(uint256) {
    bytes memory nodekey = GetTx(address(0xAFFFFFFFFF000002)).getTx().signatures[0].rawkey;
    uint256 nodeid=node_ids[nodekey];
    _set_attr(nodeid, attribs);
    return 1;
  }

  function _set_attr(uint256 nodeid, uint256[2][] calldata attribs) internal {
    require(nodeid>0,"unknown node");
    for(uint256 i=0;i<attribs.length;i++){
      attrib[nodeid][attribs[i][0]]=attribs[i][1];
    }
  }


  function _register(bytes memory shortkey) internal returns (uint256) {
    if(node_ids[shortkey]==0){
      require(nodes<252,"maximum number of nodes reached");
      nodes++;
      node_ids[shortkey]=nodes;
      node_keys[nodes]=shortkey;
      emit RegisterNode(nodes,shortkey);
    }
    return node_ids[shortkey];
  }

  function set_nodekind(bytes calldata nodekey, NodeKind k) public returns (NodeKind res) {
    require(msg.sender==address(chainmgmt) ||
            msg.sender == owner(),"Only chain management can change node kind");
    uint256 slice=nodekey.length-32;
    uint256 nodeid=node_ids[nodekey[slice:]];
    require(nodeid>0,"Node unknown");
    NodeKind old=node_kind[nodeid];
    if(old==k)
      return old;

    node_kind[nodeid]=k;
    if(k==NodeKind.NODE_CONSENSUS){
      _update_consensus(nodeid,true);
    }else if(old==NodeKind.NODE_CONSENSUS){
      _update_consensus(nodeid,false);
    }
    return old;
  }

  function _update_consensus(uint256 nodeid, bool allow) private {
    require(nodeid<254,"Incorrect node_id");
    uint8 bit=uint8(nodeid);
    uint256 node_mask=1<<bit;
    if((node_mask & consensus_mask) == 0){
      require(allow,"incorrect update");
      consensus_nodes+=1;
      consensus_mask=consensus_mask | node_mask;
    }else{
      require(!allow,"incorrect update");
      consensus_nodes-=1;
      consensus_mask=consensus_mask & ~node_mask;
    }
    minsig=(consensus_nodes/2)+1;
  }

  function register(bytes calldata nodekey) public returns (uint256) {
    require(self_registration,"Self registration disabled");
    uint256 slice=nodekey.length-32;
    return _register(nodekey[slice:]);
  }

  function register() public returns (uint256) {
    require(self_registration,"Self registration disabled");
    bytes memory nodekey = GetTx(address(0xAFFFFFFFFF000002)).getTx().signatures[0].rawkey;
    return _register(nodekey);
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
    bytes memory nodekey = GetTx(address(0xAFFFFFFFFF000002)).getTx().signatures[0].rawkey;
    uint256 nodeid=node_ids[nodekey];
    require(nodeid>0,"unknown node");
    node_addr[nodeid]=msg.sender;
    res=new bool[](data.length);
    for(uint i=0;i<data.length;i++){
      res[i]=_updateData(nodeid, data[i]);
    }
  }
  function updateData(hUpd[] calldata data, uint256[2][] calldata attribs) public returns (bool[] memory res) {
    bytes memory nodekey = GetTx(address(0xAFFFFFFFFF000002)).getTx().signatures[0].rawkey;
    uint256 nodeid=node_ids[nodekey];
    require(nodeid>0,"unknown node");
    node_addr[nodeid]=msg.sender;
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

  //function for tests
  function _updateDataRaw(uint256 from, uint256 height, uint8[] calldata visible) public returns (bool) {
    require(test_mode,"Disabled in production mode");
    require(last_height[from]<height,"Already seen it");
    if(height<=calc_till) return false;
    if(block.number > epoch_start_blk+1)
      if(height<epoch_start_blk) return false;
    else
      if(height<epoch_last_start_blk) return false;

    uint8 cnt=blocknode_sigcnt[height];
    for(uint8 n=0;n<cnt;n++){ //already has report from the node
      if (blocknode_sigmask[height][n][0]==from)
        return false;
    }

    uint i=0;
    uint256 sigmask=0;
    for(i=0;i<visible.length;i++){
      uint256 nid=visible[i];
      if(nid>0){ //ignore signatures from unknown nodes
        sigmask|=(1<<uint8(nid-1));
      }
    }

    blocknode_sigmask[height].push([from-1,sigmask]);
    blocknode_sigcnt[height]=cnt+1;

    last_height[from]=height;
    return true;
  }

  function _updateData(uint256 from, hUpd calldata data) internal returns (bool) {
    require(last_height[from]<data.height,"Already seen it");
    if(data.height<=calc_till) return false;
    if(block.number > epoch_start_blk+1)
      if(data.height<epoch_start_blk) return false;
    else
      if(data.height<epoch_last_start_blk) return false;

    uint8 cnt=blocknode_sigcnt[data.height];
    for(uint8 n=0;n<cnt;n++){ //already has report from the node
      if (blocknode_sigmask[data.height][n][0]==from)
        return false;
    }

    uint i=0;
    uint256 sigmask=0;
    for(i=0;i<data.sigs.length;i++){
      uint256 nid=node_ids[data.sigs[i].pubkey];
      if(nid>0){ //ignore signatures from unknown nodes
        sigmask|=(1<<uint8(nid-1));
      }
    }

    blocknode_sigmask[data.height].push([from,sigmask]);
    blocknode_sigcnt[data.height]=cnt+1;

    last_height[from]=data.height;
    return true;
  }

  function _node_inc_stat(uint256 node) internal {
    if(node_stat[node] & (1<<250) != 0){
      node_stat[node]+=1;
    }else{
      node_stat[node]=(1<<250);
    }
  }

  function _node_dec_stat(uint256 node) internal {
    if(node_stat[node] & (1<<251) != 0){
      node_stat[node]+=1;
    }else{
      node_stat[node]=(1<<251);
    }
  }

  function popcnt(uint256 value) public pure returns (uint256) {
    uint256 count = 0;

    // Brian Kernighan's algorithm: clear the least significant set bit until `value` becomes 0
    while (value > 0) {
      value &= (value - 1); // clears the lowest set bit
      count++;
    }

    return count;
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
}

