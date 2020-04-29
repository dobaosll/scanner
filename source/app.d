import core.thread;
import std.base64;
import std.bitmanip;
import std.conv;
import std.digest;
import std.datetime.stopwatch;
import std.functional;
import std.stdio;
import std.string;

import cemi;
import dobaosll_client;
import mprop_reader;
import transport_connections;
import util;

void main(string[] args) {
  writeln("hello, friend: ", args);

  ubyte[] lines;
  if (args.length >= 2) {
    string[] lines_str = args[1..$];
    foreach(string line_addr; lines_str) {
      try {
        lines ~= subnetworkStr2byte(line_addr);
      } catch(Exception e) {
        writeln(e.message);
        return;
      }
    }
  }

  MPropReader mprop = new MPropReader();
  ubyte[] local_descr = mprop.read(83);
  ubyte[] local_sn = mprop.read(11);
  ubyte local_sub = mprop.read(57)[0];
  ubyte local_addr = mprop.read(58)[0];
  ushort local_ia = to!ushort(local_sub << 8 | local_addr);

  if (args.length < 2) {
    // if no line was provided in args, use BAOS module line
    lines ~= local_sub;
  }

  foreach(ubyte sub; lines) {
    string lineStr = to!string(sub >> 4) ~ "." ~ to!string(sub & 0xf);
    writeln("Scanning line ", lineStr);
    for(ubyte ia = 1; ia < 255; ia += 1) {
      Thread.sleep(50.msecs);
      ushort addr = sub*256 + ia;
      if (addr == local_ia) {
        writefln("Local\t%s\t[Descr: %s. SN: %s.]", 
            ia2str(local_ia), toHexString(local_descr), toHexString(local_sn));
        continue;
      }
      auto tc = new TransportConnection(addr);
      tc.connect();
      if (!tc.connected) {
        // writefln("Device %s not connected", ia2str(addr));
        continue;
      }
      ubyte[] descr;
      ubyte[] serial;
      ubyte[] manufacturer;
      string name = " --- ";
      try {
        descr = tc.deviceDescriptorRead();
        Thread.sleep(50.msecs);
      } catch(Exception e) {
        //        writefln("Error getting device %s descriptor: %s",
        //            ia2str(addr), e.message);
      }
      try {
        // manufacturer code: Obj 0, PID 12, num 1, start 01
        manufacturer = tc.propertyRead(0x00, 0x0c, 0x01, 0x01);
      }  catch(Exception e) {
        //        writefln("Error getting device %s manufacturer code: %s",
        //                ia2str(addr), e.message);
      }
      try {
        // serialnum: Obj 0, PID 11, num 1, start 1
        serial = tc.propertyRead(0x00, 0x0b, 0x01, 0x01);
        Thread.sleep(50.msecs);
      } catch(Exception e) {
        //        writefln("Error getting device %s serial number: %s",
        //           ia2str(addr), e.message);
      }
      try {
        // description string: Obj 0, PID 21, num 1, start 0
        ubyte[] name_len_raw = tc.propertyRead(0x00, 0x15, 0x01, 0x00);
        if (name_len_raw.length == 2) {
          ushort name_len = name_len_raw.read!ushort();
          if (name_len > 0) {
            name = "";
            // restrict maximum name length to 10 symbols
            // Net N' node receives it chunk by chunk, chunk len is 10
            ushort bytes_left = name_len;
            ubyte start = 0x01;
            string getChunk() {
              string res;
              if (bytes_left > 10) {
                char[] chars = cast(char[])(tc.propertyRead(0x00, 0x15, 0x0a, start));
                bytes_left = to!ushort(bytes_left - 10);
                start += 10;
                res = to!string(chars);
              } else {
                char[] chars = cast(char[])(tc.propertyRead(0x00, 0x15,
                      to!ubyte(bytes_left), start));
                bytes_left = 0;
                res = to!string(chars);
              }

              return res;
            }
            while(bytes_left > 0) {
              name = name ~ getChunk();
              Thread.sleep(50.msecs);
            }
          }
          Thread.sleep(50.msecs);
        }
      } catch(Exception e) {
        //        writefln("Error getting device %s name: %s", 
        //            ia2str(addr), e.message);
      } finally {
        tc.disconnect();
        writefln("Device\t%s\t[Descr: %s. SN: %s. Manuf-r: %s. Name: %s.]",
            ia2str(addr), toHexString(descr),
            toHexString(serial), toHexString(manufacturer), name);
      }
    }
  }

  writeln("bye, friend");
}
