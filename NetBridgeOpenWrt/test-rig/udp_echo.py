#!/usr/bin/env python3
"""UDP echo for the router test rig: replies 'echo:' + payload. Usage: udp_echo.py ADDR PORT"""
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((sys.argv[1], int(sys.argv[2])))
while True:
    d, a = s.recvfrom(2048)
    s.sendto(b"echo:" + d, a)
