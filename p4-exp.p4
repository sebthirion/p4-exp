/* -*- P4_16 -*- */
#include <core.p4>
#include <psa.p4>

const bit<8>  UDP_PROTOCOL = 0x11;
const bit<16> TYPE_IPV4 = 0x800;
const bit<16> MRI_PORT = 5000;

#define MAX_HOPS 9

/*************************************************************************
*********************** H E A D E R S  ***********************************
*************************************************************************/

typedef bit<48> EthernetAddress;
typedef bit<32> IPAddress;
typedef bit<32> SwitchId;
typedef bit<32> QDepth;

header ethernet_t {
    EthernetAddress dstAddr;
    EthernetAddress srcAddr;
    bit<16>         etherType;
}

header ipv4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> totalLen;
    bit<16> identification;
    bit<3>  flags;
    bit<13> fragOffset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> hdrChecksum;
    IPAddress srcAddr;
    IPAddress dstAddr;
}

header udp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<16> totalLen;
    bit<16> checksum;
}

header mri_t {
    bit<16>  count;
}

header switch_t {
    SwitchId  swid;
    QDepth    qdepth;
    bit<32>   enq_timestamp;
    bit<32>   deq_timedelta;
    bit<48>   ingress_global_timestamp;
}

struct fwd_metadata_t {
    bit<32> outport;
}

header clone_i2e_metadata_t {
    bit<8> custom_tag;
    EthernetAddress srcAddr;
}

struct empty_metadata_t {
}

struct ingress_metadata_t {
    bit<16>  count;
}

struct parser_metadata_t {
    bit<16>  remaining;
}

struct metadata {
    ingress_metadata_t ingress_meta;
    parser_metadata_t parser_meta;
    fwd_metadata_t fwd_meta;
    clone_i2e_metadata_t clone_meta;
    bit<3> custom_clone_id;
}

struct headers {
    ethernet_t         ethernet;
    ipv4_t             ipv4;
    udp_t              udp;
    mri_t              mri;
    switch_t[MAX_HOPS] swtraces;
}

error { IPHeaderTooShort }

/*************************************************************************
*********************** P A R S E R  ***********************************
*************************************************************************/

parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta) {

    state start {
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_IPV4 : parse_ipv4;
            default   : accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            17            : parse_udp;
            default       : accept;
        }
    }

    state parse_udp {
        packet.extract(hdr.udp);
        transition select(hdr.udp.dstPort) {
            MRI_PORT      : parse_mri;
            default       : accept;
        }
    }

    state parse_mri {
        packet.extract(hdr.mri);
        meta.parser_meta.remaining = hdr.mri.count;
        transition select(meta.parser_meta.remaining) {
            0       : accept;
            default : parse_swtrace;
        }
    }

    state parse_swtrace {
        packet.extract(hdr.swtraces.next);
        meta.parser_meta.remaining = meta.parser_meta.remaining  - 1;
        transition select(meta.parser_meta.remaining) {
            0       : accept;
            default : parse_swtrace;
        }
    }    
}

parser IngressParserImpl(packet_in packet, 
                     out headers hdr, 
                     inout metadata meta,
                     in psa_ingress_parser_input_metadata_t istd,
                     in empty_metadata_t resubmit_meta,
                     in empty_metadata_t recirculate_meta) {
    MyParser() p;

    state start {
        p.apply(packet, hdr, meta);
        transition accept;
    }
}

parser EgressParserImpl(packet_in packet,
                    out headers hdr,
                    inout metadata user_meta,
                    in psa_egress_parser_input_metadata_t istd,
                    in metadata normal_meta,
                    in clone_i2e_metadata_t clone_i2e_meta,
                    in empty_metadata_t clone_e2e_meta) {
    MyParser() p;

    state start {
        transition select(istd.packet_path) {
            PacketPath_t.NORMAL : parse_ethernet;
        }
    }

    state parse_ethernet {
        p.apply(packet, hdr, user_meta);
        transition accept;
    }
}

/*************************************************************************
**************  I N G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control ingress(inout headers hdr,
                inout metadata user_meta, 
                in psa_ingress_input_metadata_t istd,
                inout psa_ingress_output_metadata_t ostd) {
    action drop() {
        ingress_drop(ostd);
    }
    
    action ipv4_forward(EthernetAddress dstAddr, PortId_t port) {
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
        send_to_port(ostd, port);
    }

    table ipv4_lpm {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            ipv4_forward;
            drop;
            NoAction;
        }
        size = 1024;
        default_action = NoAction();
    }

    table controller {
        actions = {
            NoAction; 
        }
        default_action = NoAction();
    }
    
    apply {
        if (hdr.ipv4.isValid()) {
            ipv4_lpm.apply();
        }
    }
}



/*************************************************************************
****************  E G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control egress(inout headers hdr,
                 inout metadata meta,
                 in psa_egress_input_metadata_t istd,
                 inout psa_egress_output_metadata_t ostd) {
    action add_swtrace(SwitchId swid) { 
        hdr.mri.count = hdr.mri.count + 1;
        hdr.swtraces.push_front(1);
        hdr.swtraces[0].swid = swid;
        /*hdr.swtraces[0].qdepth = (qdepth_t)standard_metadata.deq_qdepth;
        hdr.swtraces[0].enq_timestamp = standard_metadata.enq_timestamp;
        hdr.swtraces[0].deq_timedelta = standard_metadata.deq_timedelta;
        hdr.swtraces[0].ingress_global_timestamp = standard_metadata.ingress_global_timestamp;*/

	    hdr.ipv4.totalLen = hdr.ipv4.totalLen + 24;
        hdr.udp.totalLen = hdr.udp.totalLen + 24;
    }

    table swtrace {
        actions = { 
	        add_swtrace; 
	        NoAction; 
        }
        default_action = NoAction();      
    }
    
    apply {
        if (hdr.mri.isValid()) {
            swtrace.apply();
        }
    }
}

/*************************************************************************
***********************  D E P A R S E R  *******************************
*************************************************************************/

control MyDeparser(packet_out packet, inout headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.udp);     
        packet.emit(hdr.mri);
        packet.emit(hdr.swtraces);      
    }
}

control IngressDeparserImpl(packet_out packet,
                        out clone_i2e_metadata_t clone_i2e_meta,
                        out empty_metadata_t resubmit_meta,
                        out metadata normal_meta,
                        inout headers hdr,
                        in metadata meta,
                        in psa_ingress_output_metadata_t istd) {
    MyDeparser() dp;
    apply {
        dp.apply(packet, hdr);
    }
}

control EgressDeparserImpl(packet_out packet,
                       out empty_metadata_t clone_e2e_meta,
                       out empty_metadata_t recirculate_meta,
                       inout headers hdr,
                       in metadata meta,
                       in psa_egress_output_metadata_t istd,
                       in psa_egress_deparser_input_metadata_t edstd) {
    MyDeparser() dp;
    InternetChecksum() ck;
    apply {
        ck.clear();
        ck.add({ hdr.ipv4.version,
	             hdr.ipv4.ihl,
                 hdr.ipv4.diffserv,
                 hdr.ipv4.totalLen,
                 hdr.ipv4.identification,
                 hdr.ipv4.flags,
                 hdr.ipv4.fragOffset,
                 hdr.ipv4.ttl,
                 hdr.ipv4.protocol,
                 hdr.ipv4.srcAddr,
                 hdr.ipv4.dstAddr });
        hdr.ipv4.hdrChecksum = ck.get();
        dp.apply(packet, hdr);
    }
}

/*************************************************************************
***********************  S W I T C H  *******************************
*************************************************************************/

IngressPipeline(IngressParserImpl(),
                ingress(),
                IngressDeparserImpl()) ip;

EgressPipeline(EgressParserImpl(),
               egress(),
               EgressDeparserImpl()) ep;

PSA_SWITCH(ip, ep) main;