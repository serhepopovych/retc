#!/usr/bin/gawk -f

# Source USRXML database parsing library.
@include "@target@/netctl/lib/awk/libusrxml.awk"

# Returns burst parameter if @burst is non zero.
# Overwise zero is returned.
function burst_param(burst)
{
	burst = int(burst);
	if (burst != 0)
		return sprintf(" burst %ukb", burst);
	return "";
}

# Return quantum parameter for given @rate if
# it's value is outside of computed rate based on
# r2q parameter and HTB min/max quantums.
# Overwise no quantum parameter is returned.
# Do not scale quantum value if @dflt_max_quantum
# is not zero.
#
function quantum_param(rate, dflt_max_quantum,  quantum)
{
	if (rate >= MIN_R2Q_CLASS_RATE) {
		if (rate <= MAX_R2Q_CLASS_RATE)
			return "";
		quantum = MAX_QUANTUM;
		if (!dflt_max_quantum) {
			quantum /= SCALE_MAX_QUANTUM;
			if (quantum < MIN_QUANTUM)
				quantum = MIN_QUANTUM;
		}
	} else {
		quantum = MIN_QUANTUM;
	}
	return sprintf(" quantum %u", quantum);
}

# Initialize root qdisc and default class with given @dflt_major_classid,
# @dflt_minor_classid, @dflt_rate, @dflt_burst and dflt_txqlen on
# interface @iface. Write output to the file @f.
#
function init_root_qdisc(f, iface, dflt_major_classid, dflt_minor_classid,
			 dflt_rate, dflt_burst, dflt_txqlen, r2q)
{
	printf "\n### %s ###\n", iface >>f;

	printf "qdisc add dev %s root handle %x: htb default %x direct_qlen %u r2q %u\n",
		iface, dflt_major_classid, dflt_minor_classid, dflt_txqlen, r2q >>f;
	printf "class add dev %s root classid %x:%x htb rate %ukbit%s%s\n",
		iface, dflt_major_classid, dflt_minor_classid,
		dflt_rate, burst_param(dflt_burst), quantum_param(dflt_rate, 1) >> f;
	printf "qdisc add dev %s parent %x:%x pfifo limit %u\n",
		iface, dflt_major_classid, dflt_minor_classid, dflt_txqlen >>f;
}

# Initialize client's class with @major_classid, @minor_classid, @rate and
# @burst. Attach @qdisc to the leaf class.
# Write output to the file @f.
#
function init_client_class(f, iface, major_classid, minor_classid,
			   rate, burst, qdisc)
{
	printf "class add dev %s root classid %x:%04x htb rate %ukbit%s%s\n",
		iface, major_classid, minor_classid,
		rate, burst_param(burst), quantum_param(rate, 0) >>f;
	printf "qdisc add dev %s parent %x:%04x %s\n",
		iface, major_classid, minor_classid, qdisc >>f;
}

# Initialize client's class with init_client_class() on the @iface.
# Redirect all traffic coming to @major_classid:@minor_classid on
# @iface to @redir_iface, so that @classid on the @iface will not
# enqueue any traffic.
#
# Class with same @major_classid:@minor_classid on @redir_iface
# finally enqueues traffic.
#
function init_client_class_redir(f, iface, redir_iface,
				 major_classid, minor_classid,
				 rate, burst, qdisc)
{
	init_client_class(f, iface, major_classid, minor_classid,
			  rate, burst, qdisc);

	printf "filter add dev %s parent %x:%04x u32 match u32 0 0 " \
		"action mirred egress redirect dev %s\n",
		iface, major_classid, minor_classid, redir_iface >>f;
}

# Initialize client's IP mapping to traffic class using IPSET
# skbinfo extension.
#
function init_client_ipset(f, userid,
			   major_classid, minor_classid,
			   dir, zones,
			   usernames, usernets,    netid)
{
	if (!usernets[userid])
		return;

	printf "\n### %s ###\n", usernames[userid] >>f;

	if (zones == "")
		zones = "all";

	if (dir == "in")
		printf "\n# in from \"%s\" zone(s) to client\n", zones >>f;
	else if (dir == "out")
		printf "\n# out to \"%s\" zone(s) from client\n", zones >>f;

	for (netid = 0; netid < usernets[userid]; netid++) {
		printf "%s skbprio %x:%04x comment %s\n",
			usernets[userid,netid],
			major_classid, minor_classid,
			usernames[userid] >>f;
	}
}

################################################################################

BEGIN{
	##
	## Initialize user database parser.
	##
	if (init_usr_xml_parser() < 0)
		exit 1;
}

{
	##
	## Parse user database.
	##
	if (run_usr_xml_parser($0) < 0)
		exit 1;
}

END{
	##
	## Finish user database parsing.
	##
	if (fini_usr_xml_parser() < 0)
		exit 1;

	##
	## Configuration.
	##

	#
	# Linux kernel HZ (from CONFIG_HZ=X in .config)
	#
	if (!HZ)
		HZ = 100;

	#
	# Setup pathes if variables are empty.
	#
	if (nctl_prefix == "")
		nctl_prefix ="@target@/netctl";
	if (retc_dir == "")
		retc_dir = nctl_prefix"/etc/retc"
	if (retc_datadir == "")
		retc_datadir = retc_dir"/data";

	#
	# Output destinations.
	#
	fqdiscs		= retc_datadir"/usrxml/tc/qdiscs.rules";
	fclasses	= retc_datadir"/usrxml/tc/classes.rules";
	fipset_in_v4	= retc_datadir"/usrxml/ipset/net2tc-in-v4.rules";
	fipset_in_v6	= retc_datadir"/usrxml/ipset/net2tc-in-v6.rules";
	fipset_out_v4	= retc_datadir"/usrxml/ipset/net2tc-out-v4.rules";
	fipset_out_v6	= retc_datadir"/usrxml/ipset/net2tc-out-v6.rules";

	#
	# Uplink interface names/templates.
	#
	if (WO_IF_TEMPL == "")
		WO_IF_TEMPL = "%WO_IF%";
	if (LO_IF_TEMPL == "")
		LO_IF_TEMPL = "%LO_IF%";
	if (IFB_IF_TEMPL == "")
		IFB_IF_TEMPL = "%IFB_IF%";

	if (WO_IF == "")
		WO_IF = WO_IF_TEMPL;
	else if (WO_IF == LO_IF)
		IFB_IF = WO_IF;
	if (LO_IF == "")
		LO_IF = LO_IF_TEMPL;
	if (IFB_IF == "")
		IFB_IF = IFB_IF_TEMPL;

	#
	# Maximum number of root classes is limited to the MINOR
	# class id field width of 16 bits, representing up to
	# 65535 classes.
	#
	# Maximum of the supported classes is limited to 16383 - 2
	# due to the traffic classification rules, where class id
	# 0 and 0x3fff is reserved and should not be used for regular
	# user traffic classes.
	#
	# Bits 14, 15 are set for L[ocal] and W[orld] traffic
	# classes respectively. Both 14 and 15 bit are clear
	# if all traffic is subject to traffic control.
	#
	MINOR_CLASSID_MIN	= 1;
	MINOR_CLASSID_MAX	= 0x3ffe;
	NCLASSIDS		= MINOR_CLASSID_MAX - MINOR_CLASSID_MIN;

	#
	# Default class.
	#
	# Major ID           : 1
	# Minor ID           : 0
	# Class ID (Maj:Min) : 1:0
	# Class speed        : 10000000kbit (10gbit)
	#
	DFLT_MAJOR_CLASSID	= 1;
	DFLT_MINOR_CLASSID	= 0;
	DFLT_CLASS_RATE		= 10 * 1000 * 1000;
	DFLT_CLASS_BURST	= DFLT_CLASS_RATE / (8 * HZ);

	#
	# Transmit queue length.
	#
	TXQLEN = (DFLT_CLASS_RATE > 1 * 1000 * 1000) ? 1000 : 100;

	#
	# r2q queue parameter, used to calculate classes quantums when
	# no quantum value explicitely specified for class.
	#
	# r2q has only meaning when bandwidth is borrowed from parent
	# class by the child classes.
	#
	# Since no class parent/child relations is used the only reason
	# to use r2q parameter is to suppress most of the warnings on
	# from HTB in kernel message buffer.
	#
	# Min/Max quantum values are taken from the net/sched/sch_htb.c.
	#
	# r2q = rate (in bps) / quantum
	#
	# Use default HTB r2q parameter value 10 and specify quantum
	# for each class whose rate is outside of range
	# [ min_quantum ... max_quantum ].
	#
	MIN_QUANTUM = 1000;
	MAX_QUANTUM = 200000;
	R2Q = 10;
	MIN_R2Q_CLASS_RATE = (R2Q * MIN_QUANTUM) * 8 / 1000; # kbit
	MAX_R2Q_CLASS_RATE = (R2Q * MAX_QUANTUM) * 8 / 1000; # kbit
	SCALE_MAX_QUANTUM = 16;
	DFLT_CLASS_QUANTUM = MAX_QUANTUM;

	##
	## Prepare traffic control configurations.
	##

	## Initialize output destinations.

	# Unlink destinations to retain ipset data consistency.
	system("rm -f " \
		fqdiscs" " \
		fclasses" " \
		fipset_in_v4" " \
		fipset_out_v4" " \
		fipset_in_v6" " \
		fipset_out_v6);

	print "\n#\n# Init root qdiscs and default traffic classes.\n#\n" >fqdiscs;
	print "\n#\n# Clients traffic classes.\n#\n" >fclasses;
	print "\n#\n# Mapping of client IP to it's download traffic class.\n#\n" >fipset_in_v4;
	print "\n#\n# Mapping of client IPv6 to it's download traffic class.\n#\n" >fipset_in_v6;
	print "\n#\n# Mapping of client IP to it's upload traffic class.\n#\n" >fipset_out_v4;
	print "\n#\n# Mapping of client IPv6 to it's upload traffic class.\n#\n" >fipset_out_v6;

	## Init root qdisc and default traffic class.

	# WO_IF
	if (WO_IF != IFB_IF) {
		init_root_qdisc(fqdiscs,
				WO_IF,
				DFLT_MAJOR_CLASSID, DFLT_MINOR_CLASSID,
				DFLT_CLASS_RATE, DFLT_CLASS_BURST,
				TXQLEN, R2Q);
	}
	# LO_IF
	if (LO_IF != IFB_IF) {
		init_root_qdisc(fqdiscs,
				LO_IF,
				DFLT_MAJOR_CLASSID, DFLT_MINOR_CLASSID,
				DFLT_CLASS_RATE, DFLT_CLASS_BURST,
				TXQLEN, R2Q);
	}
	# IFB_IF
	init_root_qdisc(fqdiscs,
			IFB_IF,
			DFLT_MAJOR_CLASSID, DFLT_MINOR_CLASSID,
			DFLT_CLASS_RATE, DFLT_CLASS_BURST,
			TXQLEN, R2Q);

	## Initialize zone and direction mappings.
	zone_f_zone["world"]	= 0x8000;
	zone_f_zone["local"]	= 0x4000;
	zone_f_zone["all"]	= 0x0000;

	zone_u_if["world"]	= WO_IF;
	zone_u_if["local"]	= LO_IF;
	zone_u_if["all"]	= IFB_IF;

	dir_f_dir["in"]		= 0x01;
	dir_f_dir["out"]	= 0x02;
	dir_f_dir["all"]	= 0x03;

	u_if_nclassid = MINOR_CLASSID_MIN;

	for (d_if in USRXML_ifusers) {
		d_if_nclassid = MINOR_CLASSID_MIN;

		d_if_has_qdisc = 0;

		nifusers = split(USRXML_ifusers[d_if], ifusers, ",");
		for (u = 1; u <= nifusers; u++) {
			userid = ifusers[u];

			# Uplink/Downlink class id limit reached: not adding class
			if (u_if_nclassid > MINOR_CLASSID_MAX ||
			    d_if_nclassid > MINOR_CLASSID_MAX)
				continue;

			f_zone_all_in = f_zone_all_out = 0;
			f_dir_all = 0;
			zones_in = zones_out = "";

			ftc_user_printed = 0;

			for (pipeid = 0; pipeid < USRXML_userpipe[userid]; pipeid++) {
				# Zone
				zone = USRXML_userpipezone[userid,pipeid];
				f_zone = zone_f_zone[zone];

				# Direction
				dir = USRXML_userpipedir[userid,pipeid];
				f_dir = dir_f_dir[dir];

				# Bandwidth is in kbit[s], burst is in kb[ytes]
				bw = USRXML_userpipebw[userid,pipeid];
				burst = bw / (8 * HZ);

				# Qdisc
				qdisc = USRXML_userpipeqdisc[userid,pipeid];

				if (qdisc != "") {
					n = USRXML_userpipeqdisc[userid,pipeid,"opts"];
					for (i = 0; i < n; i++)
						qdisc = qdisc " " USRXML_userpipeqdisc[userid,pipeid,"opts",i];
				} else {
					# By default "pfifo" limit is 1 packet. This is sane
					# default in case of no client qdisc after parsing XML.
					qdisc = "pfifo limit " TXQLEN;
				}

				## TC

				if (!ftc_user_printed) {
					printf "\n### %s ###\n", USRXML_usernames[userid] >>fclasses;
					ftc_user_printed = 1;
				}

				# In
				if (and(f_dir, dir_f_dir["in"])) {
					# Init root qdisc and default class on user interfce
					if (!d_if_has_qdisc) {
						init_root_qdisc(fqdiscs,
								d_if,
								DFLT_MAJOR_CLASSID, DFLT_MINOR_CLASSID,
								DFLT_CLASS_RATE, DFLT_CLASS_BURST,
								TXQLEN, R2Q);
						d_if_has_qdisc = 1;
					}

					printf "\n# in from \"%s\" zone to client\n", zone >>fclasses;

					minor_classid = or(d_if_nclassid, f_zone);
					f_zone_all_in = or(f_zone_all_in, f_zone);

					init_client_class(fclasses, d_if,
							  DFLT_MAJOR_CLASSID, minor_classid,
							  bw, burst, qdisc);

					zones_in = (zones_in == "") ? zone : zones_in"/"zone;
				}

				# Out
				if (and(f_dir, dir_f_dir["out"])) {
					printf "\n# out to \"%s\" zone from client\n", zone >>fclasses;

					u_if = zone_u_if[zone];

					if (WO_IF == LO_IF) {
						minor_classid = or(u_if_nclassid, f_zone);
						f_zone_all_out = or(f_zone_all_out, f_zone);
					} else {
						minor_classid = u_if_nclassid;

						if (f_zone == 0) {
							init_client_class_redir(fclasses, LO_IF, u_if,
										DFLT_MAJOR_CLASSID, minor_classid,
										bw, burst, qdisc);
							print "" >>fclasses;

							init_client_class_redir(fclasses, WO_IF, u_if,
										DFLT_MAJOR_CLASSID, minor_classid,
										bw, burst, qdisc);
							print "" >>fclasses;
						}
					}

					init_client_class(fclasses, u_if,
							  DFLT_MAJOR_CLASSID, minor_classid,
							  bw, burst, qdisc);

					zones_out = (zones_out == "") ? zone : zones_out"/"zone;
				}

				f_dir_all = or(f_dir_all, f_dir);
			}

			## IPSET

			# In
			if (and(f_dir_all, dir_f_dir["in"])) {
				minor_classid = or(f_zone_all_in, d_if_nclassid++);

				# v4
				init_client_ipset(fipset_in_v4, userid,
						  DFLT_MAJOR_CLASSID, minor_classid,
						  "in", zones_in,
						  USRXML_usernames, USRXML_usernets);
				# v6
				init_client_ipset(fipset_in_v6, userid,
						  DFLT_MAJOR_CLASSID, minor_classid,
						  "in", zones_in,
						  USRXML_usernames, USRXML_usernets6);
			}

			# Out
			if (and(f_dir_all, dir_f_dir["out"])) {
				minor_classid = or(f_zone_all_out, u_if_nclassid++);

				# v4
				init_client_ipset(fipset_out_v4, userid,
						  DFLT_MAJOR_CLASSID, minor_classid,
						  "out", zones_out,
						  USRXML_usernames, USRXML_usernets);
				# v6
				init_client_ipset(fipset_out_v6, userid,
						  DFLT_MAJOR_CLASSID, minor_classid,
						  "out", zones_out,
						  USRXML_usernames, USRXML_usernets6);
			}
		}
	}
}
