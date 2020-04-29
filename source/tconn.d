// TODO: transport layer connections
// 
module transport_connections;

import core.thread;
import core.time;
import std.bitmanip;
import std.conv;
import std.datetime.stopwatch;
import std.functional;
import std.stdio;

import cemi;
import dobaosll_client;

enum ERR_ACK_TIMEOUT = "ACK_TIMEOUT";
enum ERR_LDATACON_TIMEOUT = "LDATACON_TIMEOUT";
enum ERR_CONNECTION_TIMEOUT = "CONNECTION_TIMEOUT";

class TransportConnection {
  private DobaosllClient ll;
  private LData_cEMI in_frame, out_frame;
  private ubyte in_seq, out_seq;
  private bool check_in_seq = false;

  public ushort address;
  public bool connected;

  private LData_cEMI waitForCon(LData_cEMI req, Duration timeout = 300.msecs) {
    LData_cEMI res;
    // wait for confirmation
    StopWatch sw;
    Duration dur;
    sw.reset();
    sw.start();
    bool con_received = false;
    bool con_timeout = false;
    while(!con_received && !con_timeout) {
      Thread.sleep(1.msecs);
      dur = sw.peek();
      con_timeout = dur > timeout;
      ll.processMessages();
      if (in_frame is null) continue;
      if (in_frame.message_code == MC.LDATA_CON &&
          in_frame.tservice == req.tservice &&
          in_frame.dest == req.dest) {
        con_received = true;
        res = in_frame;
      }
      in_frame = null;
    }
    if (con_timeout) {
      throw new Exception(ERR_LDATACON_TIMEOUT);
    }

    return res;
  }
  private LData_cEMI waitForAck(LData_cEMI req, Duration timeout = 3000.msecs) {
    LData_cEMI res;
    // wait for confirmation
    bool ack_received = false;
    StopWatch sw;
    Duration dur;
    sw.reset();
    sw.start();
    bool ack_timeout = false;
    while(!ack_received && !ack_timeout) {
      Thread.sleep(1.msecs);
      dur = sw.peek();
      ack_timeout = dur > timeout;
      ll.processMessages();
      if (in_frame is null) continue;
      if (in_frame.message_code == MC.LDATA_IND &&
          in_frame.tservice == TService.TAck &&
          in_frame.source == req.dest &&
          in_frame.tseq == req.tseq) {
        ack_received = true;
        res = in_frame;
      }
      in_frame = null;
    }
    if (ack_timeout) {
      throw new Exception(ERR_ACK_TIMEOUT);
    }

    return res;
  }
  private LData_cEMI waitForResponse(LData_cEMI req, APCI apci, Duration timeout = 6000.msecs) {
    LData_cEMI res;
    // wait for confirmation
    bool res_received = false;
    StopWatch sw;
    Duration dur;
    sw.reset();
    sw.start();
    bool res_timeout = false;
    while(!res_received && !res_timeout) {
      Thread.sleep(1.msecs);
      dur = sw.peek();
      res_timeout = dur > timeout;
      ll.processMessages();
      if (in_frame is null) continue;
      if (in_frame.message_code == MC.LDATA_IND &&
          in_frame.tservice == TService.TDataConnected &&
          in_frame.apci == apci &&
          in_frame.source == req.dest) {
        res_received = true;
        res = in_frame;
      }
      in_frame = null;
    }
    if (res_timeout) {
      throw new Exception(ERR_CONNECTION_TIMEOUT);
    }

    return res;
  }

  private void onCemiFrame(ubyte[] frame) {
    //writefln("Received: %(%x %)", frame);
    ubyte mc = frame.peek!ubyte(0);
    if (mc == MC.LDATA_REQ || 
        mc == MC.LDATA_CON ||
        mc == MC.LDATA_IND) {
      in_frame = new LData_cEMI(frame);
    }
  }
  private void increaseInSeq() {
    if (in_seq < 15) {
      in_seq += 1;
    } else {
      in_seq = 0;
    }
  }
  private void increaseOutSeq() {
    if (out_seq < 15) {
      out_seq += 1;
    } else {
      out_seq = 0;
    }
  }
  private void sendAck() {
    // send ack
    LData_cEMI tack = new LData_cEMI();
    tack.message_code = MC.LDATA_REQ;
    tack.address_type_group = false;
    tack.source = 0x0000;
    tack.dest = address;
    tack.tservice = TService.TAck;
    tack.tseq = in_seq;
    increaseInSeq();
    ll.sendCemi(tack.toUbytes());
  }
  this(ushort ia) {
    address = ia;
    ll = new DobaosllClient();
    ll.onCemi(toDelegate(&onCemiFrame));
  }

  public void connect() {
    LData_cEMI tconn = new LData_cEMI();
    tconn.message_code = MC.LDATA_REQ;
    tconn.address_type_group = false;
    tconn.source = 0x0000;
    tconn.dest = address;
    tconn.tservice = TService.TConnect;
    ll.sendCemi(tconn.toUbytes());
    bool confirmed = false;
    LData_cEMI con;
    while (!confirmed) {
      try {
        con = waitForCon(tconn);
        confirmed = true;
      } catch(Exception e) {
        ll.sendCemi(tconn.toUbytes());
      }
    }
    if (con.error) {
      connected = false;
      return;
    }
    connected = true;
    in_seq = 0x00;
    out_seq = 0x00;
  }
  public void disconnect() {
    LData_cEMI tdcon = new LData_cEMI();
    tdcon.message_code = MC.LDATA_REQ;
    tdcon.address_type_group = false;
    tdcon.source = 0x0000;
    tdcon.dest = address;
    tdcon.tservice = TService.TDisconnect;
    ll.sendCemi(tdcon.toUbytes());
    connected = false;
  }
  private LData_cEMI requestResponse(LData_cEMI req, APCI apci_res) {
    if (!connected) {
      throw new Exception("ERR_DISCONNECTED");
    }
    LData_cEMI result;
    ll.sendCemi(req.toUbytes());
    bool confirmed = false;
    while(!confirmed) {
      try {
        waitForCon(req);
        confirmed = true;
      } catch(Exception e) {
        ll.sendCemi(req.toUbytes());
      }
    }
    // while ack not received or sent count < 4
    auto ack_timeout_dur = 3000.msecs;
    auto sent_cnt = 1;
    bool acknowledged = false;
    while (!acknowledged && sent_cnt < 4) {
      try {
        waitForAck(req, ack_timeout_dur);
        acknowledged = true;
        increaseOutSeq();
      } catch(Exception e) {
        ll.sendCemi(req.toUbytes());
        //ack_timeout_dur = 1000.msecs;
        sent_cnt += 1;
      }
    }
    if (!acknowledged) {
      disconnect();
      throw new Exception(ERR_ACK_TIMEOUT);
    }
    try {
      result = waitForResponse(req, apci_res);
      if (check_in_seq && result.tseq == in_seq) {
        sendAck();
      } else if (!check_in_seq) {
        sendAck();
      } else if (check_in_seq && result.tseq != in_seq){
        disconnect();
        throw new Exception("ERR_WRONG_SEQ_NUM");
      }
    } catch(Exception e) {
      disconnect();
      throw e;
    }

    return result;
  }
  public ubyte[] deviceDescriptorRead(ubyte descr_type = 0x00) {
    ubyte[] result;
    LData_cEMI dread = new LData_cEMI();
    dread.message_code = MC.LDATA_REQ;
    dread.address_type_group = false;
    dread.source = 0x0000;
    dread.dest = address;
    dread.tservice = TService.TDataConnected;
    dread.tseq = out_seq;
    dread.apci = APCI.ADeviceDescriptorRead;
    dread.apci_data_len = 1;
    dread.tiny_data = descr_type;

    result = requestResponse(dread, APCI.ADeviceDescriptorResponse).data;

    return result;
  }
  public ubyte[] propertyRead(ubyte obj_id, ubyte prop_id, ubyte num, ushort start) {
    ubyte[] result;
    // get serial number
    LData_cEMI dprop = new LData_cEMI();
    dprop.message_code = MC.LDATA_REQ;
    dprop.address_type_group = false;
    dprop.source = 0x0000;
    dprop.dest = address;
    dprop.tservice = TService.TDataConnected;
    dprop.tseq = out_seq;
    dprop.apci = APCI.APropertyValueRead;
    dprop.apci_data_len = 5;
    dprop.data.length = 4;
    dprop.data.write!ubyte(obj_id, 0);
    dprop.data.write!ubyte(prop_id, 1);
    ushort numstart = start & 0b000011111111;
    numstart = to!ushort((num << 12) | numstart);
    dprop.data.write!ushort(numstart, 2);
    ll.sendCemi(dprop.toUbytes());
    result = requestResponse(dprop, APCI.APropertyValueResponse).data;

    if(result.length >= 4) {
      ubyte res_obj_id = result.read!ubyte();
      ubyte res_prop_id = result.read!ubyte();
      ushort res_numstart = result.read!ushort();
      if (res_obj_id != obj_id &&
          res_prop_id != prop_id &&
          res_numstart != numstart) {
        throw new Exception("ERR_WRONG_RESPONSE");
      }

    } else {
      throw new Exception("ERR_WRONG_RESPONSE");
    }

    return result;
  }
}
