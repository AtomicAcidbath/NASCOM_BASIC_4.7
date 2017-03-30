;==============================================================================
; Contents of parts of this file are copyright Grant Searle
;
; You have permission to use this for NON COMMERCIAL USE ONLY
; If you wish to use it elsewhere, please include an acknowledgement to myself.
;
; http://searle.hostei.com/grant/index.html
;
; eMail: home.micros01@btinternet.com
;
; If the above don't work, please perform an Internet search to see if I have
; updated the web page hosting service.
;
;==============================================================================
;
; ACIA 6850 interrupt driven serial I/O to run modified NASCOM Basic 4.7.
; Full input and output buffering with incoming data hardware handshaking.
; Handshake shows full before the buffer is totally filled to
; allow run-on from the sender. Transmit and receive are interrupt driven.
;
; https://github.com/feilipu/
; https://feilipu.me/
;
;==============================================================================

SER_CTRL_ADDR   .EQU   $80    ; Address of Control Register (write only)
SER_STATUS_ADDR .EQU   $80    ; Address of Status Register (read only)
SER_DATA_ADDR   .EQU   $81    ; Address of Data Register

SER_CLK_DIV_01  .EQU   $00    ; Divide the Clock by 1
SER_CLK_DIV_16  .EQU   $01    ; Divide the Clock by 16
SER_CLK_DIV_64  .EQU   $02    ; Divide the Clock by 64 (default value)
SER_RESET       .EQU   $03    ; Master Reset (issue before any other Control word)

SER_7E2         .EQU   $00    ; 7 Bits Even Parity 2 Stop Bits
SER_7O2         .EQU   $04    ; 7 Bits  Odd Parity 2 Stop Bits
SER_7E1         .EQU   $08    ; 7 Bits Even Parity 1 Stop Bit
SER_7O1         .EQU   $0C    ; 7 Bits  Odd Parity 1 Stop Bit
SER_8N2         .EQU   $10    ; 8 Bits   No Parity 2 Stop Bits
SER_8N1         .EQU   $14    ; 8 Bits   No Parity 1 Stop Bit
SER_8E1         .EQU   $18    ; 8 Bits Even Parity 1 Stop Bit
SER_8O1         .EQU   $1C    ; 8 Bits  Odd Parity 1 Stop Bit

SER_TDI_RTS0    .EQU   $00    ; _RTS low,  Transmitting Interrupt Disabled
SER_TEI_RTS0    .EQU   $20    ; _RTS low,  Transmitting Interrupt Enabled
SER_TDI_RTS1    .EQU   $40    ; _RTS high, Transmitting Interrupt Disabled
SER_TDI_BRK     .EQU   $60    ; _RTS low,  Transmitting Interrupt Disabled, BRK on Tx

SER_TEI_MASK    .EQU   $60    ; Mask for the Tx Interrupt & RTS bits   

SER_REI         .EQU   $80    ; Receive Interrupt Enabled

SER_RDRF        .EQU   $01    ; Receive Data Register Full
SER_TDRE        .EQU   $02    ; Transmit Data Register Empty
SER_DCD         .EQU   $04    ; Data Carrier Detect
SER_CTS         .EQU   $08    ; Clear To Send
SER_FE          .EQU   $10    ; Framing Error (Received Byte)
SER_OVRN        .EQU   $20    ; Overrun (Received Byte
SER_PE          .EQU   $40    ; Parity Error (Received Byte)
SER_IRQ         .EQU   $80    ; IRQ (Either Transmitted or Received Byte)

RAM_START       .EQU   $2000  ; Start of RAM

SER_RX_BUFSIZE  .EQU     $FF  ; FIXED Rx buffer size, 256 Bytes, no range checking
SER_RX_FULLSIZE .EQU     SER_RX_BUFSIZE - $08
                              ; Fullness of the Rx Buffer, when not_RTS is signalled
SER_RX_EMPTYSIZE .EQU    $08  ; Fullness of the Rx Buffer, when RTS is signalled

SER_TX_BUFSIZE  .EQU     $0F  ; Size of the Tx Buffer, 15 Bytes

serRxBuf        .EQU     $RAM_START ; must start on 0xnn00 for low byte roll-over
serTxBuf        .EQU     serRxBuf+SER_RX_BUFSIZE+1
serRxInPtr      .EQU     serTxBuf+SER_TX_BUFSIZE+1
serRxOutPtr     .EQU     serRxInPtr+2
serTxInPtr      .EQU     serRxOutPtr+2
serTxOutPtr     .EQU     serTxInPtr+2
serRxBufUsed    .EQU     serTxOutPtr+2
serTxBufUsed    .EQU     serRxBufUsed+1
serControl      .EQU     serTxBufUsed+1
basicStarted    .EQU     serControl+1

WRKSPC          .EQU     RAM_START+$0120 ; set BASIC Work space WRKSPC
                                         ; beyond the end of ACIA stuff

TEMPSTACK       .EQU     WRKSPC+$0AB ; Top of BASIC line input buffer
                                     ; (CURPOS = WRKSPC+0ABH)
                                     ; so it is "free ram" when BASIC resets

CR              .EQU     0DH
LF              .EQU     0AH
CS              .EQU     0CH   ; Clear screen

;==================================================================================
;
; Z80 INTERRUPT VECTOR SECTION 
;

;------------------------------------------------------------------------------
; RST 00 - Reset

                .ORG     0000H
RST00:           DI            ;Disable interrupts
                 JP      INIT  ;Initialize Hardware and go

;------------------------------------------------------------------------------
; RST 08 - Tx a character over RS232

                .ORG     0008H
RST08:           JP      TXA

;------------------------------------------------------------------------------
; RST 10 - Rx a character over RS232 Channel A [Console], hold until char ready

                .ORG     0010H
RST10:           JP      RXA

;------------------------------------------------------------------------------
; RST 18 - Check serial Rx status

                .ORG     0018H
RST18:           JP      RXA_CHK

;------------------------------------------------------------------------------
; RST 20

                .ORG     0020H
RST20:          RET            ; just return

;------------------------------------------------------------------------------
; RST 28

                .ORG     0028H
RST28:          RET            ; just return

;------------------------------------------------------------------------------
; RST 30
;
                .ORG     0030H
RST30:          RET            ; just return

;------------------------------------------------------------------------------
; RST 38 - INTERRUPT VECTOR [ ACIA for IM 1 ]

                .ORG     0038H
RST38:                 
serialInt:
        push af
        push hl
                                    ; start doing the Rx stuff

        in a, (SER_STATUS_ADDR)     ; get the status of the ACIA
        and SER_RDRF                ; check whether a byte has been received
        jr z, im1_tx_check          ; if not, go check for bytes to transmit 

        in a, (SER_DATA_ADDR)       ; Get the received byte from the ACIA 
        ld l, a                     ; Move Rx byte to l

        ld a, (serRxBufUsed)        ; Get the number of bytes in the Rx buffer
        cp SER_RX_BUFSIZE           ; check whether there is space in the buffer
        jr nc, im1_tx_check         ; buffer full, check if we can send something

        ld a, l                     ; get Rx byte from l
        ld hl, (serRxInPtr)         ; get the pointer to where we poke
        ld (hl), a                  ; write the Rx byte to the serRxInPtr address

        inc l                       ; move the Rx pointer low byte along, 0xFF rollover
        ld (serRxInPtr), hl         ; write where the next byte should be poked

        ld hl, serRxBufUsed
        inc (hl)                    ; atomically increment Rx buffer count


im1_tx_check:                       ; now start doing the Tx stuff
        ld a, (serTxBufUsed)        ; get the number of bytes in the Tx buffer
        or a                        ; check whether it is zero
        jr z, im1_tei_clear         ; if the count is zero, then disable the Tx Interrupt

        in a, (SER_STATUS_ADDR)     ; get the status of the ACIA
        and SER_TDRE                ; check whether a byte can be transmitted
        jr z, im1_rts_check         ; if not, go check for the receive RTS selection

        ld hl, (serTxOutPtr)        ; get the pointer to place where we pop the Tx byte
        ld a, (hl)                  ; get the Tx byte
        out (SER_DATA_ADDR), a      ; output the Tx byte to the ACIA

        inc hl                      ; move the Tx pointer along
        ld a, l                     ; get the low byte of the Tx pointer
        cp (serTxBuf + SER_TX_BUFSIZE) & $FF
        jr nz, im1_tx_no_wrap
        ld hl, serTxBuf             ; we wrapped, so go back to start of buffer

im1_tx_no_wrap:
        ld (serTxOutPtr), hl        ; write where the next byte should be popped

        ld hl, serTxBufUsed
        dec (hl)                    ; atomically decrement current Tx count
        jr nz, im1_txa_end          ; if we've more Tx bytes to send, we're done for now
        
im1_tei_clear:
        ld a, (serControl)          ; get the ACIA control echo byte
        and ~SER_TEI_MASK           ; mask out the Tx interrupt bits
        or SER_TDI_RTS0             ; mask out (disable) the Tx Interrupt, keep RTS low
        ld (serControl), a          ; write the ACIA control byte back
        out (SER_CTRL_ADDR), a      ; Set the ACIA CTRL register

im1_rts_check:
        ld a, (serRxBufUsed)        ; get the current Rx count    	
        cp SER_RX_FULLSIZE          ; compare the count with the preferred full size
        jr c, im1_txa_end           ; leave the RTS low, and end

        ld a, (serControl)          ; get the ACIA control echo byte
        and ~SER_TEI_MASK           ; mask out the Tx interrupt bits
        or SER_TDI_RTS1             ; Set RTS high, and disable Tx Interrupt
        ld (serControl), a          ; write the ACIA control echo byte back
        out (SER_CTRL_ADDR), a	    ; Set the ACIA CTRL register

im1_txa_end:
        pop hl
        pop af

        ei
        reti

;------------------------------------------------------------------------------
RXA:
rxa_wait_for_byte:
        ld a, (serRxBufUsed)        ; get the number of bytes in the Rx buffer

        or a                        ; see if there are zero bytes available
        jr z, rxa_wait_for_byte     ; wait, if there are no bytes available
        
        push hl                     ; Store HL so we don't clobber it

        ld hl, (serRxOutPtr)        ; get the pointer to place where we pop the Rx byte
        ld a, (hl)                  ; get the Rx byte
        ld i, a                     ; save the Rx byte in I

        inc l                       ; move the Rx pointer low byte along
        ld (serRxOutPtr), hl        ; write where the next byte should be popped

        ld hl,serRxBufUsed
        dec (hl)                    ; atomically decrement Rx count
        ld a,(hl)                   ; get the newly decremented Rx count

        cp SER_RX_EMPTYSIZE         ; compare the count with the preferred empty size
        jr nc, rxa_clean_up         ; if the buffer is too full, don't change the RTS

        di                          ; critical section begin
        ld a, (serControl)          ; get the ACIA control echo byte
        and ~SER_TEI_MASK           ; mask out the Tx interrupt bits
        or SER_TDI_RTS0             ; set RTS low.
        ld (serControl), a          ; write the ACIA control echo byte back
        out (SER_CTRL_ADDR), a      ; set the ACIA CTRL register
        ei                          ; critical section end

rxa_clean_up:
        ld a, i                     ; get the Rx byte from I
        pop hl                      ; recover HL
        ret                         ; char ready in A

;------------------------------------------------------------------------------
TXA:
        ld i, a                     ; Store Tx character in I

        ld a, (serTxBufUsed)        ; Get the number of bytes in the Tx buffer
        or a                        ; check whether the buffer is empty
        jr nz, txa_buffer_out       ; buffer not empty, so abandon immediate Tx

        in a, (SER_STATUS_ADDR)     ; get the status of the ACIA
        and SER_TDRE                ; check whether a byte can be transmitted
        jr z, txa_buffer_out        ; if not, so abandon immediate Tx

        ld a, i                     ; Retrieve Tx character from I
        out (SER_DATA_ADDR), a      ; immediately output the Tx byte to the ACIA

        ret                         ; and just complete

txa_buffer_out:
        ld a, (serTxBufUsed)        ; Get the number of bytes in the Tx buffer
        cp SER_TX_BUFSIZE           ; check whether there is space in the buffer
        jr nc, txa_buffer_out       ; buffer full, so wait till it has space

        ld a, i                     ; Retrieve Tx character
        push hl                     ; Store HL so we don't clobber it
        
        ld hl, (serTxInPtr)         ; get the pointer to where we poke
        ld (hl), a                  ; write the Tx byte to the serTxInPtr

        inc hl                      ; move the Tx pointer along
        ld a, l                     ; move low byte of the Tx pointer
        cp (serTxBuf + SER_TX_BUFSIZE) & $FF
        jr nz, txa_no_wrap
        ld hl, serTxBuf             ; we wrapped, so go back to start of buffer

txa_no_wrap:
        ld (serTxInPtr), hl         ; write where the next byte should be poked

        ld hl, serTxBufUsed
        inc (hl)                    ; atomic increment of Tx count

        pop hl                      ; recover HL

txa_clean_up:
        di                          ; critical section begin
        ld a, (serControl)          ; get the ACIA control echo byte
        and ~SER_TEI_MASK           ; mask out the Tx interrupt bits
        or SER_TEI_RTS0             ; set RTS low. if the TEI was not set, it will work again
        ld (serControl), a          ; write the ACIA control echo byte back
        out (SER_CTRL_ADDR), a      ; set the ACIA CTRL register
        ei                          ; critical section end
        ret

;------------------------------------------------------------------------------
RXA_CHK:
        LD        A,(serRxBufUsed)
        CP        $0
        RET

;------------------------------------------------------------------------------
PRINT:
        LD        A,(HL)          ; Get character
        OR        A               ; Is it $00 ?
        RET       Z               ; Then RETurn on terminator
        CALL      TXA             ; Print it
        INC       HL              ; Next Character
        JR        PRINT           ; Continue until $00

;------------------------------------------------------------------------------
INIT:
               LD        SP,TEMPSTACK ; Set up a temporary stack

               LD        HL,serRxBuf     ; Initialise Rx Buffer
               LD        (serRxInPtr),HL
               LD        (serRxOutPtr),HL

               LD        HL,serTxBuf     ; Initialise Tx Buffer
               LD        (serTxInPtr),HL
               LD        (serTxOutPtr),HL              

               XOR       A               ; 0 the accumulator
               LD        (serRxBufUsed),A
               LD        (serTxBufUsed),A

               LD        A, SER_RESET    ; Master Reset the ACIA
               OUT       (SER_CTRL_ADDR),A

               LD        A, SER_REI|SER_TDI_RTS0|SER_8N1|SER_CLK_DIV_64
                                         ; load the default ACIA configuration
                                         ; 8n1 at 115200 baud
                                         ; receive interrupt enabled
                                         ; transmit interrupt disabled
                                    
               LD        (serControl),A     ; write the ACIA control byte echo
               OUT       (SER_CTRL_ADDR),A  ; output to the ACIA control byte

               IM        1               ; interrupt mode 1
               EI
START:
               LD        HL, SIGNON1     ; Sign-on message
               CALL      PRINT           ; Output string
               LD        A,(basicStarted); Check the BASIC STARTED flag
               CP        'Y'             ; to see if this is power-up
               JR        NZ, COLDSTART   ; If not BASIC started then always do cold start
               LD        HL, SIGNON2     ; Cold/warm message
               CALL      PRINT           ; Output string
CORW:
               RST       10H
               AND       11011111B       ; lower to uppercase
               CP        'C'
               JR        NZ, CHECKWARM
               RST       08H
               LD        A,$0D
               RST       08H
               LD        A,$0A
               RST       08H
COLDSTART:
               LD        A,'Y'           ; Set the BASIC STARTED flag
               LD        (basicStarted),A
               JP        $0390           ; <<<< Start Basic COLD:
CHECKWARM:
               CP        'W'
               JR        NZ, CORW
               RST       08H
               LD        A,$0D
               RST       08H
               LD        A,$0A
               RST       08H
WARMSTART:
               JP        $0393           ; <<<< Start Basic WARM:

;==============================================================================
;
; STRINGS
;
SIGNON1:       .BYTE     "SBC - Grant Searle",CR,LF
               .BYTE     "ACIA - feilipu",CR,LF,0

SIGNON2:       .BYTE     CR,LF
               .BYTE     "Cold or Warm start"
               .BYTE     " (C|W) ? ",0

;==============================================================================
;
               .END
;
;==============================================================================
