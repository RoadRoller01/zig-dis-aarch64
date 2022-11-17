const std = @import("std");
const Register = @import("utils.zig").Register;
const Width = @import("utils.zig").Width;
const Field = @import("utils.zig").Field;

const AddSubInstr = @import("instruction.zig").AddSubInstr;
const AesInstr = @import("instruction.zig").AesInstr;
const BitfieldInstr = @import("instruction.zig").BitfieldInstr;
const BranchCondInstr = @import("instruction.zig").BranchCondInstr;
const BranchInstr = @import("instruction.zig").BranchInstr;
const CompBranchInstr = @import("instruction.zig").CompBranchInstr;
const ConCompInstr = @import("instruction.zig").ConCompInstr;
const Condition = @import("instruction.zig").Condition;
const CvtInstr = @import("instruction.zig").CvtInstr;
const DataProcInstr = @import("instruction.zig").DataProcInstr;
const ExceptionInstr = @import("instruction.zig").ExceptionInstr;
const ExtractInstr = @import("instruction.zig").ExtractInstr;
const FMovInstr = @import("instruction.zig").FMovInstr;
const FPCompInstr = @import("instruction.zig").FPCompInstr;
const FPCondCompInstr = @import("instruction.zig").FPCondCompInstr;
const FPCondSelInstr = @import("instruction.zig").FPCondSelInstr;
const HintInstr = @import("instruction.zig").HintInstr;
const Instruction = @import("instruction.zig").Instruction;
const LoadStoreInstr = @import("instruction.zig").LoadStoreInstr;
const LogInstr = @import("instruction.zig").LogInstr;
const MovInstr = @import("instruction.zig").MovInstr;
const PCRelAddrInstr = @import("instruction.zig").PCRelAddrInstr;
const SIMDDataProcInstr = @import("instruction.zig").SIMDDataProcInstr;
const ShaInstr = @import("instruction.zig").ShaInstr;
const SysInstr = @import("instruction.zig").SysInstr;
const SysRegMoveInstr = @import("instruction.zig").SysRegMoveInstr;
const SysWithRegInstr = @import("instruction.zig").SysWithRegInstr;
const SysWithResInstr = @import("instruction.zig").SysWithResInstr;
const TestInstr = @import("instruction.zig").TestInstr;

const Error = error{ EndOfStream, Unallocated, Unimplemented };

pub const Disassembler = struct {
    const Self = @This();

    code: []const u8,
    stream: std.io.FixedBufferStream([]const u8),

    pub fn init(code: []const u8) Self {
        return .{
            .code = code,
            .stream = std.io.fixedBufferStream(code),
        };
    }

    pub fn next(self: *Self) Error!?Instruction {
        const reader = self.stream.reader();

        const op = reader.readIntLittle(u32) catch return null;

        const op0 = op >> 31;
        const op1 = @truncate(u4, op >> 25);

        switch (op1) {
            0b0000 => return try if (op0 == 0) decodeReserve(op) else decodeSME(op), // Reserved and SME
            0b0001 => return error.Unallocated,
            0b0010 => return try decodeSVE(op), // SVE encoding
            0b0011 => return error.Unallocated,
            0b1000, 0b1001 => return try decodeDataProcImm(op), // Data processing - Imm
            0b1010, 0b1011 => return try decodeBranchExcpSysInstr(op), // Branches, exceptions, system instructions
            0b0100, 0b0110, 0b1100, 0b1110 => return try decodeLoadStore(op), // Load/Store
            0b0101, 0b1101 => return try decodeDataProcReg(op), // Data processing - Reg
            0b0111, 0b1111 => return try decodeDataProcScalarFPSIMD(op), // Data processing - Scalar FP and SIMD
        }
    }

    fn decodeReserve(op: u32) Error!Instruction {
        _ = op;
        return error.Unimplemented;
    }

    fn decodeSME(op: u32) Error!Instruction {
        _ = op;
        return error.Unimplemented;
    }

    fn decodeSVE(op: u32) Error!Instruction {
        _ = op;
        return error.Unimplemented;
    }

    fn decodeDataProcImm(op: u32) Error!Instruction {
        const op0 = @truncate(u3, op >> 23);

        return switch (op0) {
            0b000, 0b001 => blk: {
                const p = op >> 31 == 1;
                const payload = PCRelAddrInstr{
                    .p = p,
                    .rd = Register.from(op, .x, false),
                    .immhi = @truncate(u19, op >> 5),
                    .immlo = @truncate(u2, op >> 29),
                };
                break :blk if (p)
                    Instruction{ .adrp = payload }
                else
                    Instruction{ .adr = payload };
            },
            0b010 => blk: {
                const s = @truncate(u1, op >> 29) == 1;
                const op1 = @truncate(u1, op >> 30);
                const width = Width.from(op >> 31);
                const payload = AddSubInstr{
                    .s = s,
                    .op = if (op1 == 0) .add else .sub,
                    .width = width,
                    .rn = Register.from(op >> 5, width, true),
                    .rd = Register.from(op, width, !s),
                    .payload = .{ .imm12 = .{
                        .sh = @truncate(u1, op >> 22),
                        .imm = @truncate(u12, op >> 10),
                    } },
                };
                break :blk if (op1 == 0)
                    Instruction{ .add = payload }
                else
                    Instruction{ .sub = payload };
            },
            0b011 => blk: {
                const o2 = @truncate(u1, op >> 2);
                const sf = @truncate(u1, op >> 31);
                const s = @truncate(u1, op >> 29) == 1;
                const add = @truncate(u1, op >> 30) == 0;
                const payload = AddSubInstr{
                    .s = s,
                    .op = if (add) .add else .sub,
                    .width = .x,
                    .rn = Register.from(op >> 5, .x, s),
                    .rd = Register.from(op, .x, s),
                    .payload = .{ .imm_tag = .{
                        .imm6 = @truncate(u6, op >> 16),
                        .imm4 = @truncate(u4, op >> 10),
                    } },
                };
                break :blk if (o2 == 1 or sf == 0 or (sf == 1 and s))
                    error.Unallocated
                else if (add)
                    Instruction{ .add = payload }
                else
                    Instruction{ .sub = payload };
            },
            0b100 => blk: {
                const width = Width.from(op >> 31);
                const n = @truncate(u1, op >> 22);
                const opc = @truncate(u2, op >> 29);
                // TODO: stage1 moment
                const LogTy = Field(LogInstr, .op);
                const log_op = switch (opc) {
                    0b00, 0b11 => LogTy.@"and",
                    0b01 => LogTy.orr,
                    0b10 => LogTy.eor,
                };
                const payload = LogInstr{
                    .s = opc == 0b11,
                    .n = @truncate(u1, op >> 22),
                    .op = log_op,
                    .width = width,
                    .rn = Register.from(op >> 5, width, false),
                    .rd = Register.from(op, width, true),
                    .payload = .{ .imm = .{
                        .immr = @truncate(u6, op >> 16),
                        .imms = @truncate(u6, op >> 10),
                    } },
                };
                break :blk if (width == .w and n == 1) error.Unallocated else switch (opc) {
                    0b00, 0b11 => Instruction{ .@"and" = payload },
                    0b01 => Instruction{ .orr = payload },
                    0b10 => Instruction{ .eor = payload },
                };
            },
            0b101 => blk: {
                const width = Width.from(op >> 31);
                const opc = @truncate(u2, op >> 29);
                const hw = @truncate(u2, op >> 21);
                const imm16 = @truncate(u16, op >> 5);
                const ext: Field(MovInstr, .ext) = if (opc == 0b00)
                    if (imm16 == 0x0000 and @truncate(u1, hw >> 1) != 0b0)
                        .none
                    else
                        .n
                else if (opc == 0b10)
                    if (imm16 == 0x0000 and !(width == .x or @truncate(u1, hw >> 1) == 0b0))
                        .none
                    else
                        .z
                else if (opc == 0b11)
                    .k
                else
                    break :blk error.Unallocated;
                break :blk if (width == .w and (hw == 0b10 or hw == 0b11))
                    error.Unallocated
                else .{ .mov = .{
                    .ext = ext,
                    .width = width,
                    .hw = hw,
                    .imm16 = imm16,
                    .rd = Register.from(op, width, false),
                } };
            },
            0b110 => blk: {
                const opc = @truncate(u2, op >> 29);
                const n = @truncate(u1, op >> 22);
                const ext = @intToEnum(Field(BitfieldInstr, .ext), opc);
                const immr = @truncate(u6, op >> 16);
                const imms = @truncate(u6, op >> 10);
                const rd_width = Width.from(op >> 31);
                const rn_width = if (ext == .signed and ((immr == 0b000000 and imms == 0b000111) or
                    (immr == 0b000000 and imms == 0b001111) or (immr == 0b000000 and imms == 0b011111)))
                    .w
                else
                    rd_width;
                break :blk if (opc == 0b11 or (rd_width == .w and n == 0b1) or (rd_width == .x and n == 0b0))
                    error.Unallocated
                else
                    Instruction{ .bfm = BitfieldInstr{
                        .opc = opc,
                        .n = n,
                        .width = rn_width,
                        .ext = ext,
                        .immr = @truncate(u6, op >> 16),
                        .imms = @truncate(u6, op >> 10),
                        .rn = Register.from(op >> 5, rn_width, false),
                        .rd = Register.from(op, rd_width, false),
                    } };
            },
            0b111 => blk: {
                const width = Width.from(op >> 31);
                const op21 = @truncate(u2, op >> 29);
                const n = @truncate(u1, op >> 22);
                const o0 = @truncate(u1, op >> 21);
                const imms = @truncate(u6, op >> 10);
                break :blk if (op21 != 0b00 or
                    (op21 == 0b00 and o0 == 1) or
                    (@enumToInt(width) == 0 and imms >= 0b100000) or
                    (@enumToInt(width) == 0 and n == 1) or
                    (@enumToInt(width) == 1 and n == 0))
                    error.Unallocated
                else
                    Instruction{ .extr = ExtractInstr{
                        .rm = Register.from(op >> 16, width, false),
                        .imms = imms,
                        .rn = Register.from(op >> 5, width, false),
                        .rd = Register.from(op, width, false),
                    } };
            },
        };
    }

    fn decodeBranchExcpSysInstr(op: u32) Error!Instruction {
        const op0 = @truncate(u3, op >> 29);
        const op1 = @truncate(u14, op >> 12);
        const op2 = @truncate(u5, op);

        if (op0 == 0b010 and op1 <= 0b01111111111111) {
            const o0 = @truncate(u1, op >> 4);
            const o1 = @truncate(u1, op >> 24);
            const payload = BranchCondInstr{
                .imm19 = @truncate(u19, op >> 5),
                .cond = @intToEnum(Condition, @truncate(u4, op)),
            };
            return if (o0 == 0b0 and o1 == 0b0)
                Instruction{ .bcond = payload }
            else if (o0 == 0b1 and o1 == 0b0)
                Instruction{ .bccond = payload }
            else
                error.Unallocated;
        } else if (op0 == 0b110 and op1 <= 0b00111111111111) {
            const opc = @truncate(u3, op >> 21);
            const opc2 = @truncate(u3, op >> 2);
            const ll = @truncate(u2, op);
            const payload = ExceptionInstr{ .imm16 = @truncate(u16, op >> 5) };
            return if (opc == 0b000 and opc2 == 0b000 and ll == 0b01)
                Instruction{ .svc = payload }
            else if (opc == 0b000 and opc2 == 0b000 and ll == 0b10)
                Instruction{ .hvc = payload }
            else if (opc == 0b000 and opc2 == 0b000 and ll == 0b11)
                Instruction{ .smc = payload }
            else if (opc == 0b001 and opc2 == 0b000 and ll == 0b00)
                Instruction{ .brk = payload }
            else if (opc == 0b010 and opc2 == 0b000 and ll == 0b00)
                Instruction{ .hlt = payload }
            else if (opc == 0b011 and opc2 == 0b000 and ll == 0b00)
                Instruction{ .tcancel = payload }
            else if (opc == 0b101 and opc2 == 0b000 and ll == 0b01)
                Instruction{ .dcps1 = payload }
            else if (opc == 0b101 and opc2 == 0b000 and ll == 0b10)
                Instruction{ .dcps2 = payload }
            else if (opc == 0b101 and opc2 == 0b000 and ll == 0b11)
                Instruction{ .dcps3 = payload }
            else
                error.Unallocated;
        } else if (op0 == 0b110 and op1 == 0b01000000110001) {
            const crm = @truncate(u4, op >> 8);
            const o2 = @truncate(u3, op >> 5);
            const payload = SysWithRegInstr{
                .rd = Register.from(op, .x, false),
            };
            return if (crm == 0b0000 and o2 == 0b000)
                Instruction{ .wfet = payload }
            else if (crm == 0b0000 and o2 == 0b001)
                Instruction{ .wfit = payload }
            else
                error.Unallocated;
        } else if (op0 == 0b110 and op1 == 0b01000000110010 and op2 == 0b11111) {
            const crm = @truncate(u4, op >> 8);
            const o2 = @truncate(u3, op >> 5);
            return if (crm == 0b0000 and o2 == 0b000)
                @as(Instruction, Instruction.nop)
            else if (crm == 0b0000 and o2 == 0b001)
                @as(Instruction, Instruction.yield)
            else if (crm == 0b0000 and o2 == 0b010)
                @as(Instruction, Instruction.wfe)
            else if (crm == 0b0000 and o2 == 0b011)
                @as(Instruction, Instruction.wfi)
            else if (crm == 0b0000 and o2 == 0b100)
                @as(Instruction, Instruction.sev)
            else if (crm == 0b0000 and o2 == 0b101)
                @as(Instruction, Instruction.sevl)
            else if (crm == 0b0000 and o2 == 0b110)
                @as(Instruction, Instruction.dgh)
            else if (crm == 0b0000 and o2 == 0b111)
                @as(Instruction, Instruction.xpac)
            else if (crm == 0b0001 and o2 == 0b000)
                @as(Instruction, Instruction.pacia1716)
            else if (crm == 0b0001 and o2 == 0b010)
                @as(Instruction, Instruction.pacib1716)
            else if (crm == 0b0001 and o2 == 0b100)
                @as(Instruction, Instruction.autia1716)
            else if (crm == 0b0001 and o2 == 0b110)
                @as(Instruction, Instruction.autib1716)
            else if (crm == 0b0010 and o2 == 0b000)
                @as(Instruction, Instruction.esb)
            else if (crm == 0b0010 and o2 == 0b001)
                @as(Instruction, Instruction.psb_csync)
            else if (crm == 0b0010 and o2 == 0b010)
                @as(Instruction, Instruction.tsb_csync)
            else if (crm == 0b0010 and o2 == 0b100)
                @as(Instruction, Instruction.csdb)
            else if (crm == 0b0011 and o2 == 0b000)
                @as(Instruction, Instruction.paciaz)
            else if (crm == 0b0011 and o2 == 0b001)
                @as(Instruction, Instruction.paciasp)
            else if (crm == 0b0011 and o2 == 0b010)
                @as(Instruction, Instruction.pacibz)
            else if (crm == 0b0011 and o2 == 0b011)
                @as(Instruction, Instruction.pacibsp)
            else if (crm == 0b0011 and o2 == 0b100)
                @as(Instruction, Instruction.autiaz)
            else if (crm == 0b0011 and o2 == 0b101)
                @as(Instruction, Instruction.autiasp)
            else if (crm == 0b0011 and o2 == 0b110)
                @as(Instruction, Instruction.autibz)
            else if (crm == 0b0011 and o2 == 0b111)
                @as(Instruction, Instruction.autibsp)
            else if (crm == 0b0100 and @truncate(u1, o2) == 0b0)
                @as(Instruction, Instruction.bti)
            else .{ .hint = .{ .imm = @as(u7, crm) << 3 | op2 } };
        } else if (op0 == 0b110 and op1 == 0b01000000110011) {
            const crm = @truncate(u4, op >> 8);
            const opc2 = @truncate(u3, op >> 5);
            const rt = @truncate(u5, op);
            return if (opc2 == 0b010 and rt == 0b11111)
                Instruction{ .clrex = @truncate(u4, op >> 8) }
            else if (opc2 == 0b100 and rt == 0b11111)
                Instruction{ .dsb = @truncate(u4, op >> 8) }
            else if (opc2 == 0b101 and rt == 0b11111)
                Instruction{ .dmb = @truncate(u4, op >> 8) }
            else if (opc2 == 0b110 and rt == 0b11111)
                Instruction{ .isb = @truncate(u4, op >> 8) }
            else if (opc2 == 0b111 and rt == 0b11111)
                @as(Instruction, Instruction.sb)
            else if (@truncate(u2, crm) == 0b10 and opc2 == 0b001 and rt == 0b11111)
                Instruction{ .dsb = @truncate(u4, op >> 8) }
            else if (crm == 0b0000 and opc2 == 0b011 and rt == 0b11111)
                @as(Instruction, Instruction.tcommit)
            else
                error.Unallocated;
        } else if (op0 == 0b110 and @truncate(u7, op1 >> 7) == 0b0100000 and @truncate(u4, op1) == 0b0100) {
            const instr1 = @truncate(u3, op >> 16);
            const instr2 = @truncate(u3, op >> 5);
            const rt = @truncate(u5, op);
            return if (instr1 == 0b000 and instr2 == 0b000 and rt == 0b11111)
                @as(Instruction, Instruction.cfinv)
            else if (instr1 == 0b000 and instr2 == 0b001 and rt == 0b11111)
                @as(Instruction, Instruction.xaflag)
            else if (instr1 == 0b000 and instr2 == 0b010 and rt == 0b11111)
                @as(Instruction, Instruction.axflag)
            else if (rt == 0b11111) blk: {
                const payload = SysRegMoveInstr{
                    .rt = Register.from(op, .x, false),
                    .op2 = @truncate(u3, op >> 5),
                    .crm = @truncate(u4, op >> 8),
                    .crn = @truncate(u4, op >> 12),
                    .op1 = @truncate(u3, op >> 16),
                    .o0 = @truncate(u1, op >> 19),
                    .o20 = @truncate(u1, op >> 20),
                    .op = .write,
                };
                break :blk Instruction{ .msr = payload };
            } else error.Unallocated;
        } else if (op0 == 0b110 and @truncate(u7, op1 >> 7) == 0b0100100) {
            const o1 = @truncate(u3, op >> 16);
            const crn = @truncate(u4, op >> 12);
            const crm = @truncate(u4, op >> 8);
            const o2 = @truncate(u3, op >> 5);
            const payload = SysWithResInstr{ .rt = Register.from(op, .x, false) };
            return if (o1 == 0b011 and crn == 0b0011 and crm == 0b0000 and o2 == 0b011)
                Instruction{ .tstart = payload }
            else if (o1 == 0b011 and crn == 0b0011 and crm == 0b0000 and o2 == 0b011)
                Instruction{ .ttest = payload }
            else
                error.Unallocated;
        } else if (op0 == 0b110 and (@truncate(u7, op1 >> 7) == 0b0100001 or @truncate(u7, op1 >> 7) == 0b0100101)) {
            const l = @truncate(u1, op >> 21) == 1;
            const payload = SysInstr{
                .l = l,
                .rt = Register.from(op, .x, false),
                .op2 = @truncate(u3, op >> 5),
                .crm = @truncate(u4, op >> 8),
                .crn = @truncate(u4, op >> 12),
                .op1 = @truncate(u3, op >> 16),
            };
            return Instruction{ .sys = payload };
        } else if (op0 == 0b110 and @truncate(u4, op1 >> 10) == 0b0100 and @truncate(u1, op1 >> 8) == 0b1) {
            const l = @truncate(u1, op >> 21) == 1;
            const payload = SysRegMoveInstr{
                .rt = Register.from(op, .x, false),
                .op2 = @truncate(u3, op >> 5),
                .crm = @truncate(u4, op >> 8),
                .crn = @truncate(u4, op >> 12),
                .op1 = @truncate(u3, op >> 16),
                .o0 = @truncate(u1, op >> 19),
                .o20 = @truncate(u1, op >> 20),
                .op = if (l) .write else .read,
            };
            return if (l)
                Instruction{ .mrs = payload }
            else
                Instruction{ .msr = payload };
        } else if (op0 == 0b110 and op1 >= 0b10000000000000) {
            const opc = @truncate(u4, op >> 21);
            const o2 = @truncate(u5, op >> 16);
            const o3 = @truncate(u6, op >> 10);
            const o4 = @truncate(u5, op);
            const rn = Register.from(op >> 5, .x, false);
            const payload = BranchInstr{ .reg = rn };
            return if (opc == 0b0000 and o2 == 0b11111 and o3 == 0b000000 and o4 == 0b00000)
                Instruction{ .br = payload }
            else if (opc == 0b0001 and o2 == 0b11111 and o3 == 0b000000 and o4 == 0b00000)
                Instruction{ .blr = payload }
            else if (opc == 0b0010 and o2 == 0b11111 and o3 == 0b000000 and o4 == 0b00000)
                Instruction{ .ret = payload }
            else if (opc == 0b0100 and o2 == 0b11111 and
                o3 == 0b000000 and o4 == 0b00000 and rn.toInt() == 0b11111)
                @as(Instruction, Instruction.eret) // TODO: stage1 moment
            else if (opc == 0b0101 and o2 == 0b11111 and
                o3 == 0b000000 and o4 == 0b00000 and rn.toInt() == 0b11111)
                @as(Instruction, Instruction.drps) // TODO: stage1 moment
            else
                error.Unimplemented; // Pauth
        } else if (op0 == 0b000 or op0 == 0b100) {
            const o = @truncate(u1, op >> 31);
            const payload = BranchInstr{ .imm = @truncate(u26, op) };
            return if (o == 0)
                Instruction{ .b = payload }
            else
                Instruction{ .bl = payload };
        } else if ((op0 == 0b001 or op0 == 0b101) and op1 <= 0b01111111111111) {
            const width = Width.from(op >> 31);
            const neg = @truncate(u1, op >> 24) == 1;
            const payload = CompBranchInstr{
                .imm19 = @truncate(u19, op >> 5),
                .rt = Register.from(op, width, false),
            };
            return if (neg)
                Instruction{ .cbnz = payload }
            else
                Instruction{ .cbz = payload };
        } else if ((op0 == 0b001 or op0 == 0b101) and op1 >= 0b10000000000000) {
            const o = @truncate(u1, op >> 24);
            const payload = TestInstr{
                .b5 = @truncate(u1, op >> 31),
                .b40 = @truncate(u5, op >> 19),
                .imm14 = @truncate(u14, op >> 5),
                .rt = Register.from(op, .x, false),
            };
            return if (o == 0)
                Instruction{ .tbz = payload }
            else
                Instruction{ .tbnz = payload };
        } else return error.Unallocated;
    }

    fn decodeLoadStore(op: u32) Error!Instruction {
        const op0 = @truncate(u4, op >> 28);
        const op1 = @truncate(u1, op >> 26);
        const op2 = @truncate(u2, op >> 23);
        const op3 = @truncate(u6, op >> 16);
        const op4 = @truncate(u2, op >> 10);
        const ExtTy = Field(LoadStoreInstr, .ext);
        const OpTy = Field(LoadStoreInstr, .op);
        const SizeTy = Field(LoadStoreInstr, .size);
        const LdStPayloadTy = Field(LoadStoreInstr, .payload);
        const IndexTy = @typeInfo(Field(LoadStoreInstr, .index)).Optional.child;
        const LdStPrfm = Field(LoadStoreInstr, .ld_st_prfm);
        if (op0 == 0b0000 and op1 == 1 and op2 <= 0b01 and op3 >= 0b100000 or
            // TODO reduce
            (op0 == 0b0000 and op1 == 1 and (op2 == 0b00 or op2 == 0b10) and @truncate(u1, op3 >> 5) == 1) or
            (op0 == 0b0000 and op1 == 1 and (op2 == 0b00 or op2 == 0b10) and @truncate(u1, op3 >> 4) == 1) or
            (op0 == 0b0000 and op1 == 1 and (op2 == 0b00 or op2 == 0b10) and @truncate(u1, op3 >> 3) == 1) or
            (op0 == 0b0000 and op1 == 1 and (op2 == 0b00 or op2 == 0b10) and @truncate(u1, op3 >> 2) == 1) or
            (op0 == 0b0000 and op1 == 1 and (op2 == 0b00 or op2 == 0b10) and @truncate(u1, op3 >> 1) == 1) or
            (op0 == 0b0000 and op1 == 1 and (op2 == 0b00 or op2 == 0b10) and @truncate(u1, op3) == 1) or
            ((op0 == 0b1000 or op0 == 0b1100) and op1 == 1))
            return error.Unallocated
        else if (op0 == 0b0000 and op1 == 1 and op2 == 0b10 and @truncate(u5, op3) == 0b11111)
            return error.Unimplemented // Advanced SIMD load/store single structure
        else if (op0 == 0b0000 and op1 == 1 and op2 == 0b11)
            return error.Unimplemented // Advanced SIMD load/store single structure (post-indexed)
        else if (op0 == 0b1101 and op1 == 0 and op2 >= 0b10 and op3 >= 0b100000)
            return error.Unimplemented // Load/store memory tags
        else if ((op0 == 0b1000 or op0 == 0b1100) and op1 == 0 and op2 == 0b00 and op3 >= 0b100000) { // Load/store exclusive pair
            const width = Width.from(op >> 30);
            const load = @truncate(u1, op >> 22) == 1;
            const o0 = @truncate(u1, op >> 15) == 1;
            const ext = if (load and o0)
                ExtTy.a
            else if (!load and o0)
                ExtTy.l
            else
                ExtTy.none;
            const rs = Register.from(op >> 16, .w, false);
            const rs_or_zero = if (rs.toInt() == 0b11111 and load)
                LdStPayloadTy{ .imm7 = 0 }
            else
                LdStPayloadTy{ .rs = rs };
            const payload = LoadStoreInstr{
                .ld_st_prfm = if (load) .ld else .st,
                .rn = Register.from(op >> 5, .x, true),
                .rt = Register.from(op, width, false),
                .rt2 = Register.from(op >> 10, width, false),
                .ext = ext,
                .op = OpTy.xp,
                .size = .none,
                .payload = rs_or_zero,
            };
            if (load)
                return Instruction{ .ld = payload }
            else
                return Instruction{ .st = payload };
        } else if (@truncate(u2, op0) == 0b00 and op1 == 0 and op2 == 0b00 and op3 <= 0b011111) { // Load/store exclusive register
            const reg_size = @truncate(u2, op >> 30);
            const load = @truncate(u1, op >> 22) == 1;
            const o0 = @truncate(u1, op >> 15) == 1;
            const width = if (reg_size == 0b11) Width.x else Width.w;
            const ext = if (load)
                if (o0) ExtTy.a else ExtTy.none
            else if (o0) ExtTy.l else ExtTy.none;
            const size = if (reg_size == 0b00) SizeTy.b else if (reg_size == 0b01) SizeTy.h else SizeTy.none;
            const rs = Register.from(op >> 16, .w, false);
            const rs_or_zero = if (rs.toInt() == 0b11111)
                LdStPayloadTy{ .imm7 = 0 }
            else
                LdStPayloadTy{ .rs = rs };
            const payload = LoadStoreInstr{
                .ld_st_prfm = if (load) .ld else .st,
                .rn = Register.from(op >> 5, .x, true),
                .rt = Register.from(op, width, false),
                .rt2 = null,
                .ext = ext,
                .op = .xr,
                .size = size,
                .payload = rs_or_zero,
            };
            return if (load)
                Instruction{ .ld = payload }
            else
                Instruction{ .st = payload };
        } else if (@truncate(u2, op0) == 0b00 and op1 == 0 and op2 == 0b01 and op3 <= 0b011111) { // Load/store ordered
            const reg_size = @truncate(u2, op >> 30);
            const load = @truncate(u1, op >> 22) == 1;
            const o0 = @truncate(u1, op >> 15) == 1;
            const width = if (reg_size == 0b11) Width.x else Width.w;
            const ext = if (load)
                if (o0) ExtTy.a else ExtTy.la
            else if (o0) ExtTy.l else ExtTy.ll;
            const size = if (reg_size == 0b00) SizeTy.b else if (reg_size == 0b01) SizeTy.h else SizeTy.none;
            const rt2 = Register.from(op >> 10, width, false);
            const rt2_or_null = if (rt2.toInt() == 0b11111) null else rt2;
            const rs = Register.from(op >> 16, width, false);
            const rs_or_zero = if (rs.toInt() == 0b11111)
                LdStPayloadTy{ .imm7 = 0 }
            else
                LdStPayloadTy{ .rs = rs };
            const payload = LoadStoreInstr{
                .ld_st_prfm = if (load) .ld else .st,
                .rn = Register.from(op >> 5, .x, true),
                .rt = Register.from(op, width, false),
                .rt2 = rt2_or_null,
                .ext = ext,
                .op = .r,
                .size = size,
                .payload = rs_or_zero,
            };
            return if (load)
                Instruction{ .ld = payload }
            else
                Instruction{ .st = payload };
        } else if (@truncate(u2, op0) == 0b00 and op1 == 0 and op2 == 0b01 and op3 >= 0b100000)
            return error.Unimplemented // Compare and swap
        else if (@truncate(u2, op0) == 0b01 and op1 == 0 and op2 >= 0b10 and op3 <= 0b011111 and op4 == 0b00) {
            const reg_size = @truncate(u2, op >> 30);
            const opc = @truncate(u2, op >> 22);
            const size = if (reg_size == 0b00)
                if (opc <= 0b01)
                    SizeTy.b
                else
                    SizeTy.sb
            else if (reg_size == 0b01)
                if (opc <= 0b01)
                    SizeTy.h
                else
                    SizeTy.sh
            else if (reg_size == 0b10 and opc == 0b10)
                SizeTy.sw
            else
                SizeTy.none;
            const ld_st: LdStPrfm = if (opc == 0b00) .st else .ld;
            const width = if (opc == 0b10 or reg_size == 0b11) Width.x else Width.w;
            const ext = if (ld_st == .ld) ExtTy.apu else ExtTy.lu;
            const payload = LoadStoreInstr{
                .ld_st_prfm = ld_st,
                .rn = Register.from(op >> 5, .x, true),
                .rt = Register.from(op, width, false),
                // TODO
                .ext = ext,
                .op = .r,
                .size = size,
                .payload = .{ .simm9 = @truncate(u9, op >> 12) },
            };
            return if ((reg_size == 0b10 and opc == 0b11) or (reg_size == 0b11 and opc >= 0b10))
                error.Unallocated
            else if (ld_st == .ld)
                Instruction{ .ld = payload }
            else
                Instruction{ .st = payload };
        } else if (@truncate(u2, op0) == 0b01 and op2 <= 0b01) {
            const opc = @truncate(u2, op >> 30);
            const v = @truncate(u1, op >> 26);
            const width = switch (@as(u3, opc) << 1 | v) {
                0b000, 0b110 => Width.w,
                0b001 => Width.s,
                0b010, 0b100 => Width.x,
                0b011 => Width.d,
                0b101 => Width.q,
                else => return error.Unallocated,
            };
            const size_ext = if (opc == 0b10 and v == 0) SizeTy.sw else SizeTy.none;
            var imm19 = @truncate(u19, op >> 5);
            const payload = LoadStoreInstr{
                .ld_st_prfm = if (opc == 0b11 and v == 0) .prfm else .ld,
                .rn = undefined,
                .rt = Register.from(op, width, false),
                .ext = .none,
                .op = .r,
                .size = size_ext,
                .payload = .{ .imm19 = imm19 },
            };
            return if (opc == 0b11 and v == 0)
                Instruction{ .prfm = payload }
            else
                Instruction{ .ld = payload };
        } else if (@truncate(u2, op0) == 0b01 and op2 >= 0b10 and op3 <= 0b011111 and op4 == 0b01)
            return error.Unimplemented // Memory Copy and Memory Set
        else if (@truncate(u2, op0) == 0b10 and op2 == 0b00) { // Load/store no-allocate pair (offset)
            const opc = @truncate(u2, op >> 30);
            const v = @truncate(u1, op >> 26);
            const load = @truncate(u1, op >> 22) == 1;
            const width = if (opc == 0b00 and v == 0)
                Width.w
            else if (opc == 0b10 and v == 0)
                Width.x
            else if (opc == 0b00 and v == 1)
                Width.s
            else if (opc == 0b01 and v == 1)
                Width.d
            else if (opc == 0b10 and v == 1)
                Width.q
            else
                return error.Unallocated;
            var simm7 = @intCast(i64, @bitCast(i7, @truncate(u7, op >> 15)));
            simm7 *%= switch (width) {
                .w, .s => 4,
                .x, .d => 8,
                .q => @as(i64, 16),
                else => unreachable,
            };
            const payload = LoadStoreInstr{
                .ld_st_prfm = if (load) .ld else .st,
                .rn = Register.from(op >> 5, .x, true),
                .rt = Register.from(op, width, false),
                .rt2 = Register.from(op >> 10, width, false),
                .ext = .none,
                .op = .np,
                .size = .none,
                .payload = .{ .simm7 = simm7 },
            };
            return if (load)
                Instruction{ .ld = payload }
            else
                Instruction{ .st = payload };
        } else if (@truncate(u2, op0) == 0b10 and op2 != 0b00) { // Load/store register pair
            const opc = @truncate(u2, op >> 30);
            const v = @truncate(u1, op >> 26);
            const load = @truncate(u1, op >> 22) == 1;
            const ext = if (opc == 0b01 and v == 0 and !load)
                ExtTy.g
            else
                ExtTy.none;
            const index = if (op2 == 0b01)
                IndexTy.post
            else if (op2 == 0b11)
                IndexTy.pre
            else
                null;
            const size = if (opc == 0b01 and v == 0 and load)
                SizeTy.sw
            else
                SizeTy.none;
            const width = if (opc == 0b00 and v == 0)
                Width.w
            else if ((opc == 0b01 and v == 0) or
                (opc == 0b10 and v == 0))
                Width.x
            else if (opc == 0b00 and v == 1)
                Width.s
            else if (opc == 0b01 and v == 1)
                Width.d
            else if (opc == 0b10 and v == 1)
                Width.q
            else
                unreachable;
            var simm7 = @intCast(i64, @bitCast(i7, @truncate(u7, op >> 15)));
            simm7 *%= if (size == .sw)
                4
            else switch (width) {
                .w, .s => 4,
                .x, .d => 8,
                .q => 16,
                else => @as(i7, 1),
            };
            const payload = LoadStoreInstr{
                .ld_st_prfm = if (load) .ld else .st,
                .rn = Register.from(op >> 5, .x, true),
                .rt = Register.from(op, width, false),
                .rt2 = Register.from(op >> 10, width, false),
                .ext = ext,
                .op = .p,
                .size = size,
                .payload = .{ .simm7 = simm7 },
                .index = index,
            };
            return if (load)
                Instruction{ .ld = payload }
            else
                Instruction{ .st = payload };
        } else if (@truncate(u2, op0) == 0b11 and op2 <= 0b01 and op3 <= 0b011111) { // Load/store register
            const size = @truncate(u2, op >> 30);
            const v = @truncate(u1, op >> 26);
            const opc = @truncate(u2, op >> 22);
            const load = switch (@truncate(u3, op >> 26) << 2 | @truncate(u2, op >> 22)) {
                0b000,
                0b100,
                0b110,
                => false,
                0b001,
                0b010,
                0b011,
                0b101,
                0b111,
                => true,
            };
            const ext = if (op4 == 0b00)
                ExtTy.u
            else if (op4 == 0b10)
                ExtTy.t
            else
                ExtTy.none;
            const index = if (op4 == 0b01)
                IndexTy.post
            else if (op4 == 0b11)
                IndexTy.pre
            else
                null;
            const width = if ((size == 0b00 and v == 0 and opc != 0b10) or
                (size == 0b01 and v == 0 and opc == 0b11) or
                (size == 0b01 and v == 0 and opc != 0b10) or
                (size == 0b10 and v == 0 and opc <= 0b01) or
                (size == 0b11 and v == 0 and opc == 0b10))
                Width.w
            else if ((size == 0b00 and v == 0 and opc == 0b10) or
                (size == 0b01 and v == 0 and opc == 0b10) or
                (size == 0b10 and v == 0 and opc == 0b10) or
                (size == 0b11 and v == 0 and opc <= 0b01))
                Width.x
            else if ((size == 0b00 and v == 1 and opc <= 0b01))
                Width.b
            else if ((size == 0b01 and v == 1 and opc <= 0b01))
                Width.h
            else if ((size == 0b10 and v == 1 and opc <= 0b01))
                Width.s
            else if ((size == 0b11 and v == 1 and opc <= 0b01))
                Width.d
            else if ((size == 0b00 and v == 1 and opc >= 0b10))
                Width.q
            else
                unreachable;
            const size_ext = if (size == 0b00 and v == 0 and opc <= 0b01)
                SizeTy.b
            else if (size == 0b00 and v == 0 and opc >= 0b10)
                SizeTy.sb
            else if (size == 0b01 and v == 0 and opc <= 0b01)
                SizeTy.h
            else if (size == 0b01 and v == 0 and opc >= 0b10)
                SizeTy.sh
            else if (size == 0b10 and v == 0 and opc == 0b10)
                SizeTy.sw
            else
                SizeTy.none;
            const ld_st_prfm = if (size == 0b11 and v == 0 and opc == 0b10)
                LdStPrfm.prfm
            else if (load)
                LdStPrfm.ld
            else
                LdStPrfm.st;
            const payload = LoadStoreInstr{
                .ld_st_prfm = ld_st_prfm,
                .rn = Register.from(op >> 5, .x, true),
                .rt = Register.from(op, width, false),
                .ext = ext,
                .op = .r,
                .size = size_ext,
                .payload = .{ .simm9 = @truncate(u9, op >> 12) },
                .index = index,
            };
            return if ((@truncate(u1, size) == 1 and v == 1 and opc >= 0b10) or
                (size >= 0b10 and v == 0 and opc == 0b11) or
                (size >= 0b10 and v == 1 and opc >= 0b10))
                error.Unallocated
            else if (size == 0b11 and v == 0 and opc == 0b10)
                Instruction{ .prfm = payload }
            else if (load)
                Instruction{ .ld = payload }
            else
                Instruction{ .st = payload };
        } else if (@truncate(u2, op0) == 0b11 and op2 <= 0b01 and op3 >= 0b100000 and op4 == 0b00) { // Atomic memory operations
            return error.Unimplemented;
        } else if (@truncate(u2, op0) == 0b11 and op2 <= 0b01 and op3 >= 0b100000 and op4 == 0b10) { // Load/store register (register offset)
            const size = @truncate(u2, op >> 30);
            const v = @truncate(u1, op >> 26);
            const opc = @truncate(u2, op >> 22);
            const option = @truncate(u3, op >> 13);
            const rn = Register.from(op >> 5, .x, true);
            const rt_width = if ((size == 0b00 and v == 0 and opc != 0b10) or
                (size == 0b01 and v == 0 and opc != 0b10) or
                (size == 0b10 and v == 0 and opc <= 0b01) or
                (size == 0b11 and v == 0 and opc == 0b10))
                Width.w
            else if ((size == 0b00 and v == 0 and opc == 0b10) or
                (size == 0b01 and v == 0 and opc == 0b10) or
                (size == 0b10 and v == 0 and opc == 0b10) or
                (size == 0b11 and v == 0 and opc <= 0b01))
                Width.x
            else if (size == 0b00 and v == 1 and opc <= 0b01)
                Width.b
            else if (size == 0b01 and v == 1 and opc <= 0b01)
                Width.h
            else if (size == 0b10 and v == 1 and opc <= 0b01)
                Width.s
            else if (size == 0b11 and v == 1 and opc <= 0b01)
                Width.d
            else if (size == 0b00 and v == 1 and opc >= 0b10)
                Width.q
            else
                return error.Unallocated;
            const rt = Register.from(op, rt_width, false);
            const size_ext = if ((size == 0b00 and v == 0 and opc == 0b00) or
                (size == 0b00 and v == 0 and opc == 0b01))
                SizeTy.b
            else if ((size == 0b00 and v == 0 and opc == 0b10) or
                (size == 0b00 and v == 0 and opc == 0b11))
                SizeTy.sb
            else if ((size == 0b01 and v == 0 and opc == 0b00) or
                (size == 0b01 and v == 0 and opc == 0b01))
                SizeTy.h
            else if ((size == 0b01 and v == 0 and opc == 0b10) or
                (size == 0b01 and v == 0 and opc == 0b11))
                SizeTy.sh
            else if (size == 0b10 and v == 0 and opc == 0b10)
                SizeTy.sw
            else
                SizeTy.none;
            const rm_width = if (@truncate(u1, option) == 0)
                Width.w
            else
                Width.x;
            const shift_not_zero = @truncate(u1, op >> 12) == 1;
            const amount = if (shift_not_zero and (rt_width == .b or size_ext == .b or size_ext == .sb))
                0
            else if (shift_not_zero and (rt_width == .h or size_ext == .h or size_ext == .sh))
                1
            else if ((shift_not_zero and (rt_width == .w or rt_width == .s)) or
                (size == 0b10 and v == 0 and opc == 0b10))
                2
            else if (shift_not_zero and (rt_width == .x or rt_width == .d))
                3
            else if (shift_not_zero and rt_width == .q)
                @as(u8, 4)
            else
                0;
            const shift = LdStPayloadTy{ .shifted_reg = .{
                .rm = Register.from(op >> 16, rm_width, false),
                .shift = shift_not_zero,
                .amount = amount,
                .shift_type = @intToEnum(
                    Field(Field(LdStPayloadTy, .shifted_reg), .shift_type),
                    option,
                ),
            } };
            const ld_st_prfm = if ((size == 0b00 and v == 0 and opc == 0b01) or
                (size == 0b00 and v == 0 and opc == 0b10) or
                (size == 0b00 and v == 0 and opc == 0b11) or
                (size == 0b00 and v == 1 and opc == 0b01) or
                (size == 0b00 and v == 1 and opc == 0b11) or
                (size == 0b01 and v == 0 and opc == 0b01) or
                (size == 0b01 and v == 0 and opc == 0b10) or
                (size == 0b01 and v == 0 and opc == 0b11) or
                (size == 0b01 and v == 1 and opc == 0b01) or
                (size == 0b10 and v == 0 and opc == 0b01) or
                (size == 0b10 and v == 0 and opc == 0b10) or
                (size == 0b10 and v == 1 and opc == 0b01) or
                (size == 0b11 and v == 0 and opc == 0b01) or
                (size == 0b11 and v == 1 and opc == 0b01))
                LdStPrfm.ld
            else if ((size == 0b00 and v == 0 and opc == 0b00) or
                (size == 0b00 and v == 1 and opc == 0b00) or
                (size == 0b00 and v == 1 and opc == 0b10) or
                (size == 0b01 and v == 0 and opc == 0b00) or
                (size == 0b01 and v == 1 and opc == 0b00) or
                (size == 0b10 and v == 0 and opc == 0b00) or
                (size == 0b10 and v == 1 and opc == 0b00) or
                (size == 0b11 and v == 0 and opc == 0b00) or
                (size == 0b11 and v == 1 and opc == 0b00))
                LdStPrfm.st
            else if (size == 0b11 and v == 0 and opc == 0b10)
                LdStPrfm.prfm
            else
                return error.Unallocated;

            const payload = LoadStoreInstr{
                .ld_st_prfm = ld_st_prfm,
                .rn = rn,
                .rt = rt,
                .ext = .none,
                .op = .r,
                .size = size_ext,
                .payload = shift,
            };
            return switch (ld_st_prfm) {
                .ld => Instruction{ .ld = payload },
                .st => Instruction{ .st = payload },
                .prfm => Instruction{ .prfm = payload },
            };
        } else if (@truncate(u2, op0) == 0b11 and op2 <= 0b01 and op3 >= 0b100000 and @truncate(u1, op4) == 0b1) { // Load/store register (pac)
            // TODO
            const load = true;
            const payload = undefined;
            return if (load)
                Instruction{ .ld = payload }
            else
                Instruction{ .st = payload };
        } else if (@truncate(u2, op0) == 0b11 and op2 >= 0b10) { // Load/store register (unsigned immediate)
            const v = @truncate(u1, op >> 26);
            const opc = @truncate(u2, op >> 22);
            const size = @truncate(u2, op >> 30);
            const SizeExt = Field(LoadStoreInstr, .size);
            const size_ext = if (size == 0b00 and v == 0 and opc <= 0b01)
                SizeExt.b
            else if (size == 0b01 and v == 0 and opc <= 0b01)
                SizeExt.h
            else if (size == 0b00 and v == 0 and opc >= 0b10)
                SizeExt.sb
            else if (size == 0b01 and v == 0 and opc >= 0b10)
                SizeExt.sh
            else if (size == 0b10 and v == 0 and opc == 0b10)
                SizeExt.sw
            else
                SizeExt.none;
            const width = if ((size == 0b11 and v == 0) or
                (size == 0b00 and v == 0 and opc == 0b10) or
                (size == 0b01 and v == 0 and opc == 0b10) or
                (size == 0b10 and v == 0 and opc == 0b10))
                Width.x
            else if (v == 0 or
                (size == 0b00 and v == 0 and opc == 0b11) or
                (size == 0b01 and v == 0 and opc == 0b11))
                Width.w
            else if (size == 0b00 and opc <= 0b01)
                Width.b
            else if (size == 0b01 and opc <= 0b01)
                Width.h
            else if (size == 0b10 and opc <= 0b01)
                Width.s
            else if (size == 0b11 and opc <= 0b01)
                Width.d
            else if (size == 0b00 and opc >= 0b10)
                Width.q
            else
                unreachable;
            const load = !((size == 0b00 and v == 0 and opc == 0b00) or
                (size == 0b00 and v == 1 and opc == 0b00) or
                (size == 0b00 and v == 1 and opc == 0b10) or
                (size == 0b01 and v == 0 and opc == 0b00) or
                (size == 0b01 and v == 1 and opc == 0b00) or
                (size == 0b10 and v == 0 and opc == 0b00) or
                (size == 0b10 and v == 1 and opc == 0b00) or
                (size == 0b11 and v == 0 and opc == 0b00) or
                (size == 0b11 and v == 1 and opc == 0b00));
            var imm12 = @truncate(u12, op >> 10);
            imm12 *%= if ((size == 0b01 and v == 0) or
                (size == 0b01 and v == 0 and opc >= 0b10))
                2
            else if (size == 0b10 and v == 0 and opc == 0b10)
                4
            else if (!(size == 0b00 and v == 0)) switch (width) {
                .h => 2,
                .w, .s => 4,
                .x, .d => 8,
                .q => 16,
                else => @as(u12, 1),
            } else 1;
            const ld_st_prfm = if (size == 0b11 and v == 0 and opc == 0b10)
                LdStPrfm.prfm
            else if (load)
                LdStPrfm.ld
            else
                LdStPrfm.st;
            const payload = LoadStoreInstr{
                .ld_st_prfm = ld_st_prfm,
                .rn = Register.from(op >> 5, .x, true),
                .rt = Register.from(op, width, false),
                .ext = .none,
                .op = .r,
                .size = size_ext,
                .payload = .{ .imm12 = imm12 },
            };
            return if ((@truncate(u1, size) == 0b1 and v == 1 and opc >= 0b10) or
                (size >= 0b10 and v == 0 and opc == 0b11) or
                (size >= 0b10 and v == 1 and opc >= 0b10))
                error.Unallocated
            else if (size == 0b11 and v == 0 and opc == 0b10)
                Instruction{ .prfm = payload }
            else if (load)
                Instruction{ .ld = payload }
            else
                Instruction{ .st = payload };
        } else return error.Unallocated;
    }

    fn decodeDataProcReg(op: u32) Error!Instruction {
        const op0 = @truncate(u1, op >> 30);
        const op1 = @truncate(u1, op >> 28);
        const op2 = @truncate(u4, op >> 21);
        const op3 = @truncate(u6, op >> 10);
        _ = op0;

        // TODO: refactor to use return on top if (fixed in stage2)
        // https://github.com/ziglang/zig/issues/10601
        if (op1 == 0) return switch (op2) {
            0b0000...0b0111 => blk: { // logical shifted reg
                const imm6 = @truncate(u6, op >> 10);
                const opc = @truncate(u2, op >> 29);
                const width = Width.from(op >> 31);
                const n = @truncate(u1, op >> 21);
                // TODO: stage1 moment
                const LogTy = Field(LogInstr, .op);
                const log_op = switch (@as(u3, opc) << 1 | n) {
                    0b000, 0b110 => LogTy.@"and",
                    0b001, 0b111 => LogTy.bic,
                    0b010 => LogTy.orr,
                    0b011 => LogTy.orn,
                    0b100 => LogTy.eor,
                    0b101 => LogTy.eon,
                };
                const payload = LogInstr{
                    .s = opc == 0b11,
                    .n = @truncate(u1, op >> 21),
                    .op = log_op,
                    .width = width,
                    // TODO: check sp
                    .rn = Register.from(op >> 5, width, false),
                    .rd = Register.from(op, width, false),
                    .payload = .{ .shift_reg = .{
                        .rm = Register.from(op >> 16, width, false),
                        .imm6 = imm6,
                        .shift = @truncate(u2, op >> 22),
                    } },
                };
                break :blk if (width == .w and imm6 >= 0b100000)
                    error.Unallocated
                else switch (log_op) {
                    .@"and" => Instruction{ .@"and" = payload },
                    .bic => Instruction{ .bic = payload },
                    .orr => Instruction{ .orr = payload },
                    .orn => Instruction{ .orn = payload },
                    .eor => Instruction{ .eor = payload },
                    .eon => Instruction{ .eon = payload },
                };
            },

            0b1000, 0b1010, 0b1100, 0b1110 => blk: { // add/sub shifted reg
                const width = Width.from(op >> 31);
                const s = @truncate(u1, op >> 29) == 1;
                const add = @truncate(u1, op >> 30) == 0;
                const payload = AddSubInstr{
                    .s = s,
                    .op = if (add) .add else .sub,
                    .width = width,
                    .rn = Register.from(op >> 5, width, false),
                    .rd = Register.from(op, width, false),
                    .payload = .{ .shift_reg = .{
                        .rm = Register.from(op >> 16, width, false),
                        .imm6 = @truncate(u6, op >> 10),
                        .shift = @truncate(u2, op >> 22),
                    } },
                };
                break :blk if (add)
                    Instruction{ .add = payload }
                else
                    Instruction{ .sub = payload };
            },

            0b1001, 0b1011, 0b1101, 0b1111 => blk: { // add/sub extended reg
                const width = Width.from(op >> 31);
                const s = @truncate(u1, op >> 29) == 1;
                const add = @truncate(u1, op >> 30) == 0;
                const opt = @truncate(u2, op >> 22);
                const imm3 = @truncate(u3, op >> 10);
                const payload = AddSubInstr{
                    .s = s,
                    .op = if (add) .add else .sub,
                    .width = width,
                    .rn = Register.from(op >> 5, width, true),
                    .rd = Register.from(op, width, !s),
                    .payload = .{ .ext_reg = .{
                        .rm = Register.from(op >> 16, width, false),
                        .option = @truncate(u3, op >> 13),
                        .imm3 = imm3,
                    } },
                };
                break :blk if (imm3 > 0b100 or opt != 0b00)
                    error.Unallocated
                else if (add)
                    Instruction{ .add = payload }
                else
                    Instruction{ .sub = payload };
            },
        } else return switch (op2) {
            0b0000 => switch (op3) {
                0b000000 => {
                    const adc = @truncate(u1, op >> 30) == 0;
                    const width = Width.from(op >> 31);
                    const payload = AddSubInstr{
                        .s = @truncate(u1, op >> 29) == 1,
                        .op = if (adc) .adc else .sbc,
                        .width = width,
                        .rn = Register.from(op >> 5, width, false),
                        .rd = Register.from(op, width, false),
                        .payload = .{ .carry = Register.from(op >> 16, width, false) },
                    };
                    return if (adc)
                        Instruction{ .adc = payload }
                    else
                        Instruction{ .sbc = payload };
                },
                0b000001, 0b100001 => error.Unimplemented, // rotr into flags
                0b000010, 0b010010, 0b100010, 0b110010 => error.Unimplemented, // eval into flags
                else => error.Unallocated,
            },

            0b0010 => { // cond compare
                const reg = @truncate(u1, op >> 11) == 0;
                const width = Width.from(op >> 31);
                const o3 = @truncate(u1, op >> 4);
                const o2 = @truncate(u1, op >> 10);
                const s = @truncate(u1, op >> 29);
                const cmn = @truncate(u1, op >> 30) == 0;
                const payload = ConCompInstr{
                    .cond = @intToEnum(Condition, @truncate(u4, op >> 12)),
                    .rn = Register.from(op >> 5, width, false),
                    .nzcv = @truncate(u4, op),
                    .payload = if (reg) .{
                        .rm = Register.from(op >> 16, width, false),
                    } else .{ .imm5 = @truncate(u5, op >> 16) },
                };
                return if (o3 == 1 or o2 == 1 or s == 0)
                    error.Unallocated
                else if (cmn)
                    Instruction{ .ccmn = payload }
                else
                    Instruction{ .ccmp = payload };
            },

            0b0100 => { // condselect
                const width = Width.from(op >> 31);
                const s = @truncate(u1, op >> 29);
                const o = @truncate(u1, op >> 30);
                const o2 = @truncate(u2, op >> 10);
                const payload = .{
                    .rm = Register.from(op >> 16, width, false),
                    .cond = @intToEnum(Condition, @truncate(u4, op >> 12)),
                    .rn = Register.from(op >> 5, width, false),
                    .rd = Register.from(op, width, false),
                };
                return if (s == 1 or o2 > 0b01)
                    error.Unallocated
                else if (o == 0 and o2 == 0b00)
                    Instruction{ .csel = payload }
                else if (o == 0 and o2 == 0b01)
                    Instruction{ .csinc = payload }
                else if (o == 1 and o2 == 0b00)
                    Instruction{ .csinv = payload }
                else if (o == 1 and o2 == 0b01)
                    Instruction{ .csneg = payload }
                else
                    error.Unallocated;
            },

            0b0110 => { // data processing 1/2 source
                const width = Width.from(op >> 31);
                const one_source = @truncate(u1, op >> 30) == 1;
                const opcode = @truncate(u6, op >> 10);
                const s = @truncate(u1, op >> 29);
                const payload = DataProcInstr{
                    // TODO: check for sp
                    .rm = if (!one_source) Register.from(op >> 16, width, false) else null,
                    .rn = Register.from(op >> 5, width, false),
                    .rd = Register.from(op, width, false),
                };
                return if (one_source) blk: {
                    const opcode2 = @truncate(u5, op >> 16);
                    const rn = @truncate(u5, op >> 5);
                    break :blk if (s == 1)
                        error.Unallocated
                    else if (opcode == 0b000000 and opcode2 == 0b00000)
                        Instruction{ .rbit = payload }
                    else if (opcode == 0b000001 and opcode2 == 0b00000)
                        Instruction{ .rev16 = payload }
                    else if (((opcode == 0b000010 and width == .w) or (opcode == 0b000011 and width == .x)) and opcode2 == 0b00000)
                        Instruction{ .rev = payload }
                    else if (opcode == 0b000100 and opcode2 == 0b00000)
                        Instruction{ .clz = payload }
                    else if (opcode == 0b000101 and opcode2 == 0b00000)
                        Instruction{ .cls = payload }
                    else if (width == .x and opcode == 0b000010 and opcode2 == 0b00000)
                        Instruction{ .rev32 = payload }
                    else if (width == .x and opcode == 0b000000 and opcode2 == 0b00001)
                        @panic("pacia")
                    else if (width == .x and opcode == 0b000001 and opcode2 == 0b00001)
                        @panic("pacib")
                    else if (width == .x and opcode == 0b000010 and opcode2 == 0b00001)
                        @panic("pacda")
                    else if (width == .x and opcode == 0b000011 and opcode2 == 0b00001)
                        @panic("pacdb")
                    else if (width == .x and opcode == 0b000100 and opcode2 == 0b00001)
                        @panic("autia")
                    else if (width == .x and opcode == 0b000101 and opcode2 == 0b00001)
                        @panic("autib")
                    else if (width == .x and opcode == 0b000110 and opcode2 == 0b00001)
                        @panic("autda")
                    else if (width == .x and opcode == 0b000111 and opcode2 == 0b00001)
                        @panic("autdb")
                    else if (width == .x and opcode == 0b001000 and opcode2 == 0b00001 and rn == 0b11111)
                        @panic("paciza")
                    else if (width == .x and opcode == 0b001001 and opcode2 == 0b00001 and rn == 0b11111)
                        @panic("pacizb")
                    else if (width == .x and opcode == 0b001001 and opcode2 == 0b00001 and rn == 0b11111)
                        @panic("pacizb")
                    else if (width == .x and opcode == 0b001010 and opcode2 == 0b00001 and rn == 0b11111)
                        @panic("pacdza")
                    else if (width == .x and opcode == 0b001011 and opcode2 == 0b00001 and rn == 0b11111)
                        @panic("pacdzb")
                    else if (width == .x and opcode == 0b001100 and opcode2 == 0b00001 and rn == 0b11111)
                        @panic("autiza")
                    else if (width == .x and opcode == 0b001101 and opcode2 == 0b00001 and rn == 0b11111)
                        @panic("autizb")
                    else if (width == .x and opcode == 0b001110 and opcode2 == 0b00001 and rn == 0b11111)
                        @panic("autiza")
                    else if (width == .x and opcode == 0b001111 and opcode2 == 0b00001 and rn == 0b11111)
                        @panic("autizb")
                    else if (width == .x and opcode == 0b010000 and opcode2 == 0b00001 and rn == 0b11111)
                        @panic("xpaci")
                    else if (width == .x and opcode == 0b010001 and opcode2 == 0b00001 and rn == 0b11111)
                        @panic("xpacd")
                    else
                        error.Unallocated;
                } else if (s == 0 and opcode == 0b000010)
                    Instruction{ .udiv = payload }
                else if (s == 0 and opcode == 0b000011)
                    Instruction{ .sdiv = payload }
                else if (s == 0 and opcode == 0b001000)
                    Instruction{ .lslv = payload }
                else if (s == 0 and opcode == 0b001001)
                    Instruction{ .lsrv = payload }
                else if (s == 0 and opcode == 0b001010)
                    Instruction{ .asrv = payload }
                else if (s == 0 and opcode == 0b001011)
                    Instruction{ .rorv = payload }
                else if (width == .w and s == 0 and opcode == 0b010000)
                    Instruction{ .crc32b = payload }
                else if (width == .w and s == 0 and opcode == 0b010001)
                    Instruction{ .crc32h = payload }
                else if (width == .w and s == 0 and opcode == 0b010010)
                    Instruction{ .crc32w = payload }
                else if (width == .w and s == 0 and opcode == 0b010100)
                    Instruction{ .crc32cb = payload }
                else if (width == .w and s == 0 and opcode == 0b010101)
                    Instruction{ .crc32ch = payload }
                else if (width == .w and s == 0 and opcode == 0b010110)
                    Instruction{ .crc32cw = payload }
                else if (width == .x and s == 0 and opcode == 0b000000)
                    Instruction{ .subp = payload }
                else if (width == .x and s == 0 and opcode == 0b000100)
                    Instruction{ .irg = payload }
                else if (width == .x and s == 0 and opcode == 0b000101)
                    Instruction{ .gmi = payload }
                else if (width == .x and s == 0 and opcode == 0b001100)
                    Instruction{ .pacga = payload }
                else if (width == .x and s == 0 and opcode == 0b010011)
                    Instruction{ .crc32x = payload }
                else if (width == .x and s == 0 and opcode == 0b010111)
                    Instruction{ .crc32cx = payload }
                else if (width == .x and s == 0 and opcode == 0b000000)
                    Instruction{ .subps = payload }
                else
                    error.Unallocated;
            },

            0b1000, 0b1001, 0b1010, 0b1011, 0b1100, 0b1101, 0b1110, 0b1111 => { // data processing 3 source
                const width = Width.from(op >> 31);
                const op54 = @truncate(u2, op >> 29);
                const op31 = @truncate(u3, op >> 21);
                const o0 = @truncate(u1, op >> 15);
                const payload = DataProcInstr{
                    .rm = if (op31 == 0b000)
                        Register.from(op >> 16, width, false)
                    else if (op31 == 0b010 or op31 == 0b110)
                        Register.from(op >> 16, .x, false)
                    else
                        Register.from(op >> 16, .w, false),
                    .ra = Register.from(op >> 10, width, false),
                    .rn = if (op31 == 0b000)
                        Register.from(op >> 5, width, false)
                    else if (op31 == 0b010 or op31 == 0b110)
                        Register.from(op >> 5, .x, false)
                    else
                        Register.from(op >> 5, .w, false),
                    .rd = Register.from(op >> 0, width, false),
                };
                return if (op54 != 0b00)
                    error.Unallocated
                else if (op31 == 0 and o0 == 0)
                    Instruction{ .madd = payload }
                else if (op31 == 0 and o0 == 1)
                    Instruction{ .msub = payload }
                else if (width == .x and op31 == 0b001 and o0 == 0)
                    Instruction{ .smaddl = payload }
                else if (width == .x and op31 == 0b001 and o0 == 1)
                    Instruction{ .smsubl = payload }
                else if (width == .x and op31 == 0b010 and o0 == 0)
                    Instruction{ .smulh = payload }
                else if (width == .x and op31 == 0b101 and o0 == 0)
                    Instruction{ .umaddl = payload }
                else if (width == .x and op31 == 0b101 and o0 == 1)
                    Instruction{ .umsubl = payload }
                else if (width == .x and op31 == 0b110 and o0 == 0)
                    Instruction{ .umulh = payload }
                else
                    error.Unallocated;
            },
            else => return error.Unallocated,
        };
    }

    fn decodeDataProcScalarFPSIMD(op: u32) Error!Instruction {
        const op0 = @truncate(u4, op >> 28);
        const op1 = @truncate(u2, op >> 23);
        const op2 = @truncate(u4, op >> 19);
        const op3 = @truncate(u9, op >> 10);
        // TODO: stage 1 moment
        const ShaOpTy = Field(ShaInstr, .op);
        const AesOpTy = Field(AesInstr, .op);
        const ArrangementTy = Field(SIMDDataProcInstr, .arrangement);
        // TODO: should be a top return
        if (op0 == 0b0100 and
            (op1 == 0b00 or op1 == 0b01) and
            @truncate(u3, op2) == 0b101 and
            @truncate(u2, op3) == 0b10 and
            @truncate(u2, op3 >> 8) == 0b00)
        {
            const aes_op = switch (@truncate(u5, op >> 12)) {
                0b00100 => AesOpTy.e,
                0b00101 => AesOpTy.d,
                0b00110 => AesOpTy.mc,
                0b00111 => AesOpTy.imc,
                else => return error.Unallocated,
            };
            const payload = AesInstr{
                .rn = Register.from(op >> 5, .v, false),
                .rd = Register.from(op, .v, false),
                .op = aes_op,
            };
            return if (@truncate(u2, op >> 22) != 0b00)
                error.Unimplemented
            else
                Instruction{ .aes = payload };
        } else if (op0 == 0b0101 and
            (op1 == 0b00 or op1 == 0b01) and
            @truncate(u1, op2 >> 2) == 0b0 and
            @truncate(u2, op3) == 0b00 and
            @truncate(u1, op3 >> 5) == 0b0)
        {
            const sha_op = switch (@as(u5, @truncate(u2, op >> 22)) << 3 | @truncate(u3, op >> 12)) {
                0b00000 => ShaOpTy.c,
                0b00001 => ShaOpTy.p,
                0b00010 => ShaOpTy.m,
                0b00011 => ShaOpTy.su0,
                0b00100 => ShaOpTy.h,
                0b00101 => ShaOpTy.h2,
                0b00110 => ShaOpTy.su1,
                else => return error.Unallocated,
            };
            const rn_width = switch (sha_op) {
                .c, .p, .m => Width.s,
                .su0, .su1 => Width.v,
                .h, .h2 => Width.q,
            };
            const rd_width = switch (sha_op) {
                .c, .p, .m, .h, .h2 => Width.q,
                .su0, .su1 => Width.v,
            };
            const payload = ShaInstr{
                .rn = Register.from(op >> 5, rn_width, false),
                .rd = Register.from(op, rd_width, false),
                .rm = Register.from(op >> 16, .v, false),
                .op = sha_op,
            };
            return switch (sha_op) {
                .c, .p, .m, .su0 => Instruction{ .sha1 = payload },
                .h, .h2, .su1 => Instruction{ .sha256 = payload },
            };
        } else if (op0 == 0b0101 and
            (op1 == 0b00 or op1 == 0b01) and
            @truncate(u3, op2) == 0b101 and
            @truncate(u2, op3) == 0b10 and
            @truncate(u2, op3 >> 8) == 0b00)
        {
            const sha_op = switch (@as(u7, @truncate(u2, op >> 22)) << 3 | @truncate(u5, op >> 12)) {
                0b0000000 => ShaOpTy.h,
                0b0000001 => ShaOpTy.su1,
                0b0000010 => ShaOpTy.su0,
                else => return error.Unallocated,
            };
            const rn_width = switch (sha_op) {
                .h => Width.s,
                .su0, .su1 => Width.v,
                else => unreachable,
            };
            const rd_width = switch (sha_op) {
                .h => Width.s,
                .su0, .su1 => Width.v,
                else => unreachable,
            };
            const payload = ShaInstr{
                .rn = Register.from(op >> 5, rn_width, false),
                .rd = Register.from(op, rd_width, false),
                .rm = null,
                .op = sha_op,
            };
            return switch (sha_op) {
                .h, .su1 => Instruction{ .sha1 = payload },
                else => Instruction{ .sha256 = payload },
            };
        } else if (@truncate(u2, op0 >> 2) == 0b01 and
            @truncate(u1, op0) == 1 and
            op1 == 0b00 and
            @truncate(u2, op2 >> 2) == 0b00 and
            @truncate(u1, op3 >> 5) == 0 and
            @truncate(u1, op3) == 1)
        {
            return error.Unimplemented; // SIMD scalar copy
        } else if (@truncate(u2, op0 >> 2) == 0b01 and
            @truncate(u1, op0) == 1 and
            op1 <= 0b01 and
            @truncate(u2, op2 >> 2) == 0b10 and
            @truncate(u2, op3 >> 4) == 0b00 and
            @truncate(u1, op3) == 0b1)
        {
            return error.Unimplemented; // SIMD three same fp16
        } else if (@truncate(u2, op0 >> 2) == 0b01 and
            @truncate(u1, op0) == 1 and
            op1 <= 0b01 and
            op2 == 0b1111 and
            @truncate(u2, op3 >> 7) == 0b00 and
            @truncate(u2, op3) == 0b10)
        {
            return error.Unimplemented; // SIMD scalar two reg misc fp16
        } else if (@truncate(u2, op0 >> 2) == 0b01 and
            @truncate(u1, op0) == 1 and
            op1 <= 0b01 and
            @truncate(u3, op2 >> 2) == 0b0 and
            @truncate(u1, op3 >> 5) == 0b1 and
            @truncate(u1, op3) == 0b1)
        {
            return error.Unimplemented; // SIMD scalar three same extra
        } else if (@truncate(u2, op0 >> 2) == 0b01 and
            @truncate(u1, op0) == 1 and
            op1 <= 0b01 and
            @truncate(u3, op2) == 0b100 and
            @truncate(u2, op3 >> 7) == 0b00 and
            @truncate(u2, op3) == 0b10)
        {
            return error.Unimplemented; // SIMD scalar two reg misc
        } else if (@truncate(u2, op0 >> 2) == 0b01 and
            @truncate(u1, op0) == 1 and
            op1 <= 0b01 and
            @truncate(u3, op2) == 0b110 and
            @truncate(u2, op3 >> 7) == 0b00 and
            @truncate(u2, op3) == 0b10)
        { // SIMD scalar pairwise
            const u = @truncate(u1, op >> 29);
            const size = @truncate(u2, op >> 22);
            const opcode = @truncate(u5, op >> 12);
            const payload = SIMDDataProcInstr{
                .arrangement = if (size == 0b11)
                    ArrangementTy.@"2d"
                else
                    return error.Unallocated,
                .rn = Register.from(op >> 5, Width.v, false),
                .rd = Register.from(op, Width.d, false),
            };
            return if (u == 0 and opcode == 0b11011)
                Instruction{ .addp = payload }
            else if (u == 0 and size <= 0b01 and opcode == 0b01100)
                @as(Instruction, Instruction.fmaxnmp)
            else if (u == 0 and size <= 0b01 and opcode == 0b01101)
                @as(Instruction, Instruction.faddp)
            else if (u == 0 and size <= 0b01 and opcode == 0b01111)
                @as(Instruction, Instruction.fmaxp)
            else if (u == 0 and size >= 0b10 and opcode == 0b01100)
                @as(Instruction, Instruction.fminnmp)
            else if (u == 0 and size >= 0b10 and opcode == 0b01111)
                @as(Instruction, Instruction.fminp)
            else if (u == 1 and size <= 0b01 and opcode == 0b01100)
                @as(Instruction, Instruction.fmaxnmp)
            else if (u == 1 and size <= 0b01 and opcode == 0b01101)
                @as(Instruction, Instruction.faddp)
            else if (u == 1 and size <= 0b01 and opcode == 0b01111)
                @as(Instruction, Instruction.fmaxp)
            else if (u == 1 and size >= 0b10 and opcode == 0b01100)
                @as(Instruction, Instruction.fminnmp)
            else if (u == 1 and size >= 0b10 and opcode == 0b01111)
                @as(Instruction, Instruction.fminp)
            else
                error.Unallocated;
        } else if (@truncate(u2, op0 >> 2) == 0b01 and
            @truncate(u1, op0) == 1 and
            op1 <= 0b01 and
            @truncate(u1, op2 >> 2) == 0b1 and
            @truncate(u2, op3) == 0b00)
        { // SIMD scalar three different
            const u = @truncate(u1, op >> 29);
            const opcode = @truncate(u4, op >> 12);
            return if (u == 0 and opcode == 0b1001)
                @as(Instruction, Instruction.sqdmlal)
            else if (u == 0 and opcode == 0b1011)
                @as(Instruction, Instruction.sqdmlsl)
            else if (u == 0 and opcode == 0b1101)
                @as(Instruction, Instruction.sqdmull)
            else
                error.Unallocated;
        } else if (@truncate(u2, op0 >> 2) == 0b01 and
            @truncate(u1, op0) == 1 and
            op1 <= 0b01 and
            @truncate(u1, op2 >> 2) == 0b1 and
            @truncate(u1, op3) == 0b1)
        { // SIMD scalar three same
            const u = @truncate(u1, op >> 29);
            const size = @truncate(u2, op >> 22);
            const opcode = @truncate(u5, op >> 11);
            return if (u == 0 and opcode == 0b00001)
                @as(Instruction, Instruction.sqadd)
            else if (u == 0 and opcode == 0b00101)
                @as(Instruction, Instruction.sqsub)
            else if (u == 0 and opcode == 0b00110)
                @as(Instruction, Instruction.cmgt)
            else if (u == 0 and opcode == 0b00111)
                @as(Instruction, Instruction.cmge)
            else if (u == 0 and opcode == 0b01000)
                @as(Instruction, Instruction.sshl)
            else if (u == 0 and opcode == 0b01001)
                @as(Instruction, Instruction.sqshl)
            else if (u == 0 and opcode == 0b01010)
                @as(Instruction, Instruction.srshl)
            else if (u == 0 and opcode == 0b10000)
                Instruction{ .add = AddSubInstr{
                    .s = false,
                    .op = .add,
                    .width = Width.d,
                    .rn = Register.from(op >> 5, Width.d, false),
                    .rd = Register.from(op, Width.d, false),
                    .payload = .{ .carry = Register.from(op >> 16, Width.d, false) },
                } }
            else if (u == 0 and opcode == 0b10001)
                @as(Instruction, Instruction.cmtst)
            else if (u == 0 and opcode == 0b10101)
                @as(Instruction, Instruction.sqdmulh)
            else if (u == 0 and size <= 0b01 and opcode == 0b11011)
                @as(Instruction, Instruction.fmulx)
            else if (u == 0 and size <= 0b01 and opcode == 0b11100)
                @as(Instruction, Instruction.fcmeq)
            else if (u == 0 and size <= 0b01 and opcode == 0b11111)
                @as(Instruction, Instruction.frecps)
            else if (u == 0 and size >= 0b10 and opcode == 0b11111)
                @as(Instruction, Instruction.frsqrts)
            else if (u == 1 and opcode == 0b00001)
                @as(Instruction, Instruction.uqadd)
            else if (u == 1 and opcode == 0b00101)
                @as(Instruction, Instruction.uqsub)
            else if (u == 1 and opcode == 0b00110)
                @as(Instruction, Instruction.cmhi)
            else if (u == 1 and opcode == 0b00111)
                @as(Instruction, Instruction.cmhs)
            else if (u == 1 and opcode == 0b01000)
                @as(Instruction, Instruction.ushl)
            else if (u == 1 and opcode == 0b01001)
                @as(Instruction, Instruction.uqshl)
            else if (u == 1 and opcode == 0b01011)
                @as(Instruction, Instruction.uqrshl)
            else if (u == 1 and opcode == 0b10000)
                Instruction{ .sub = undefined }
            else if (u == 1 and opcode == 0b10001)
                @as(Instruction, Instruction.cmeq)
            else if (u == 1 and opcode == 0b10110)
                @as(Instruction, Instruction.sqrdmulh)
            else if (u == 1 and opcode == 0b11100)
                @as(Instruction, Instruction.fcmge)
            else if (u == 1 and opcode == 0b11101)
                @as(Instruction, Instruction.facge)
            else if (u == 1 and opcode == 0b11010)
                @as(Instruction, Instruction.fabd)
            else if (u == 1 and opcode == 0b11100)
                @as(Instruction, Instruction.fcmgt)
            else if (u == 1 and opcode == 0b11101)
                @as(Instruction, Instruction.facgt)
            else
                error.Unallocated;
        } else if (@truncate(u2, op0 >> 2) == 0b01 and
            @truncate(u1, op0) == 1 and
            op1 == 0b10 and
            @truncate(u1, op3) == 0b1)
        {
            return error.Unimplemented; // SIMD scalar shift by immediate
        } else if (@truncate(u2, op0 >> 2) == 0b01 and
            @truncate(u1, op0) == 1 and
            op1 >= 0b10 and
            @truncate(u1, op3) == 0b0)
        {
            return error.Unimplemented; // SIMD scalar x indexed element
        } else if (@truncate(u1, op0 >> 3) == 0b0 and
            @truncate(u2, op0) == 0b00 and
            op1 <= 0b01 and
            @truncate(u1, op2 >> 2) == 0b0 and
            @truncate(u1, op3 >> 5) == 0b0 and
            @truncate(u2, op3) == 0b00)
        {
            return error.Unimplemented; // SIMD table lookup
        } else if (@truncate(u1, op0 >> 3) == 0b0 and
            @truncate(u2, op0) == 0b00 and
            op1 <= 0b01 and
            @truncate(u1, op2 >> 2) == 0b0 and
            @truncate(u1, op3 >> 5) == 0b0 and
            @truncate(u2, op3) == 0b10)
        {
            return error.Unimplemented; // SIMD permute
        } else if (@truncate(u1, op0 >> 3) == 0b0 and
            @truncate(u2, op0) == 0b10 and
            op1 <= 0b01 and
            @truncate(u1, op2 >> 2) == 0b0 and
            @truncate(u1, op3 >> 5) == 0b0 and
            @truncate(u1, op3) == 0b0)
        {
            return error.Unimplemented; // SIMD extract
        } else if (@truncate(u1, op0 >> 3) == 0b0 and
            @truncate(u1, op0) == 0b0 and
            op1 == 0b00 and
            @truncate(u2, op2 >> 2) == 0b00 and
            @truncate(u1, op3 >> 5) == 0b0 and
            @truncate(u1, op3) == 0b1)
        { // SIMD copy
            const q = @truncate(u1, op >> 30);
            const u = @truncate(u1, op >> 29);
            const imm5 = @truncate(u5, op >> 16);
            const imm4 = @truncate(u4, op >> 11);
            return if (u == 0b0 and imm4 == 0b0000)
                Instruction{ .dup = SIMDDataProcInstr{
                    .arrangement = if (@truncate(u1, imm5) == 0b1 and q == 0b0)
                        ArrangementTy.@"8b"
                    else if (@truncate(u1, imm5) == 0b1 and q == 0b1)
                        ArrangementTy.@"16b"
                    else if (@truncate(u2, imm5) == 0b10 and q == 0b0)
                        ArrangementTy.@"4h"
                    else if (@truncate(u2, imm5) == 0b10 and q == 0b1)
                        ArrangementTy.@"8h"
                    else if (@truncate(u3, imm5) == 0b100 and q == 0b0)
                        ArrangementTy.@"2s"
                    else if (@truncate(u3, imm5) == 0b100 and q == 0b1)
                        ArrangementTy.@"4s"
                    else if (@truncate(u4, imm5) == 0b1000 and q == 0b1)
                        ArrangementTy.@"2d"
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, Width.v, false),
                    .rd = Register.from(op, Width.v, false),
                    .post_index = if (@truncate(u1, imm5) == 0b1)
                        @truncate(u4, imm5 >> 1)
                    else if (@truncate(u2, imm5) == 0b10)
                        @truncate(u3, imm5 >> 2)
                    else if (@truncate(u3, imm5) == 0b100)
                        @truncate(u2, imm5 >> 3)
                    else if (@truncate(u4, imm5) == 0b1000)
                        @truncate(u1, imm5 >> 4)
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b0 and imm4 == 0b0001) blk: {
                const width = if (@truncate(u1, imm5) == 0b1 or
                    @truncate(u2, imm5) == 0b10 or
                    @truncate(u3, imm5) == 0b100)
                    Width.w
                else if (@truncate(u4, imm5) == 0b1000) Width.x else return error.Unallocated;
                break :blk Instruction{ .dup = SIMDDataProcInstr{
                    .arrangement = if (@truncate(u1, imm5) == 0b1 and q == 0b0)
                        ArrangementTy.@"8b"
                    else if (@truncate(u1, imm5) == 0b1 and q == 0b1)
                        ArrangementTy.@"16b"
                    else if (@truncate(u2, imm5) == 0b10 and q == 0b0)
                        ArrangementTy.@"4h"
                    else if (@truncate(u2, imm5) == 0b10 and q == 0b1)
                        ArrangementTy.@"8h"
                    else if (@truncate(u3, imm5) == 0b100 and q == 0b0)
                        ArrangementTy.@"2s"
                    else if (@truncate(u3, imm5) == 0b100 and q == 0b1)
                        ArrangementTy.@"4s"
                    else if (@truncate(u4, imm5) == 0b1000 and q == 0b1)
                        ArrangementTy.@"2d"
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, width, false),
                    .rd = Register.from(op, .v, false),
                } };
            } else if (u == 0b0 and imm4 == 0b0101) blk: {
                const width = if (q == 0b0) Width.w else Width.x;
                break :blk Instruction{ .smov = SIMDDataProcInstr{
                    .arrangement = if (@truncate(u1, imm5) == 0b1)
                        ArrangementTy.b
                    else if (@truncate(u2, imm5) == 0b10)
                        ArrangementTy.h
                    else if (width == .x and @truncate(u3, imm5) == 0b100)
                        ArrangementTy.s
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, width, false),
                    .post_index = if (@truncate(u1, imm5) == 0b1)
                        @truncate(u4, imm5 >> 1)
                    else if (@truncate(u2, imm5) == 0b10)
                        @truncate(u3, imm5 >> 2)
                    else if (width == .x and @truncate(u3, imm5) == 0b100)
                        @truncate(u2, imm5 >> 3)
                    else
                        return error.Unallocated,
                } };
            } else if ((q == 0b0 or (q == 0b1 and @truncate(u4, imm5) == 0b1000)) and
                u == 0b0 and imm4 == 0b0111)
            blk: {
                const width = if (q == 0b0) Width.w else Width.x;
                const payload = SIMDDataProcInstr{
                    .arrangement = if (width == .w and @truncate(u1, imm5) == 0b1)
                        ArrangementTy.b
                    else if (width == .w and @truncate(u2, imm5) == 0b10)
                        ArrangementTy.h
                    else if (width == .w and @truncate(u3, imm5) == 0b100)
                        ArrangementTy.s
                    else if (width == .x and @truncate(u4, imm5) == 0b1000)
                        ArrangementTy.d
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, width, false),
                    .post_index = if (width == .w and @truncate(u1, imm5) == 0b1)
                        @truncate(u4, imm5 >> 1)
                    else if (width == .w and @truncate(u2, imm5) == 0b10)
                        @truncate(u3, imm5 >> 2)
                    else if (width == .w and @truncate(u3, imm5) == 0b100)
                        @truncate(u2, imm5 >> 3)
                    else if (width == .x and @truncate(u4, imm5) == 0b1000)
                        @truncate(u1, imm5 >> 4)
                    else
                        return error.Unallocated,
                };
                break :blk if ((width == .w and @truncate(u3, imm5) == 0b100) or
                    (width == .x and @truncate(u4, imm5) == 0b1000))
                    Instruction{ .vector_mov = payload }
                else
                    Instruction{ .umov = payload };
            } else if (q == 0b1 and (u == 0b1 or (u == 0b0 and imm4 == 0b0011))) blk: {
                const width = if (u == 0b1)
                    Width.v
                else if (@truncate(u1, imm5) == 0b1)
                    Width.w
                else if (@truncate(u2, imm5) == 0b10)
                    Width.w
                else if (@truncate(u3, imm5) == 0b100)
                    Width.w
                else if (@truncate(u4, imm5) == 0b1000)
                    Width.x
                else
                    return error.Unallocated;
                break :blk Instruction{ .ins = SIMDDataProcInstr{
                    .arrangement = if (@truncate(u1, imm5) == 0b1)
                        ArrangementTy.b
                    else if (@truncate(u2, imm5) == 0b10)
                        ArrangementTy.h
                    else if (@truncate(u3, imm5) == 0b100)
                        ArrangementTy.s
                    else if (@truncate(u4, imm5) == 0b1000)
                        ArrangementTy.d
                    else
                        undefined,
                    .index = if (@truncate(u1, imm5) == 0b1)
                        @truncate(u4, imm5 >> 1)
                    else if (@truncate(u2, imm5) == 0b10)
                        @truncate(u3, imm5 >> 2)
                    else if (@truncate(u3, imm5) == 0b100)
                        @truncate(u2, imm5 >> 3)
                    else if (@truncate(u4, imm5) == 0b1000)
                        @truncate(u1, imm5 >> 4)
                    else
                        undefined,
                    .rn = Register.from(op >> 5, width, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (u == 0b1)
                        if (@truncate(u1, imm5) == 0b1)
                            imm4
                        else if (@truncate(u2, imm5) == 0b10)
                            @truncate(u3, imm4 >> 1)
                        else if (@truncate(u3, imm5) == 0b100)
                            @truncate(u2, imm4 >> 2)
                        else if (@truncate(u4, imm5) == 0b1000)
                            @truncate(u1, imm4 >> 3)
                        else
                            undefined
                    else
                        null,
                } };
            } else error.Unallocated;
        } else if (@truncate(u1, op0 >> 3) == 0b0 and
            @truncate(u1, op0) == 0b0 and
            op1 <= 0b01 and
            @truncate(u2, op2 >> 2) == 0b10 and
            @truncate(u2, op3 >> 4) == 0b00 and
            @truncate(u1, op3) == 0b1)
        {
            return error.Unimplemented; // SIMD three same (fp16)
        } else if (@truncate(u1, op0 >> 3) == 0b0 and
            @truncate(u1, op0) == 0b0 and
            op1 <= 0b01 and
            op2 == 0b1111 and
            @truncate(u2, op3 >> 7) == 0b00 and
            @truncate(u2, op3) == 0b10)
        {
            return error.Unimplemented; // SIMD two reg misc (fp16)
        } else if (@truncate(u1, op0 >> 3) == 0b0 and
            @truncate(u1, op0) == 0b0 and
            op1 <= 0b01 and
            @truncate(u1, op2 >> 2) == 0b0 and
            @truncate(u1, op3 >> 5) == 0b1 and
            @truncate(u1, op3) == 0b1)
        {
            return error.Unimplemented; // SIMD three reg extension
        } else if (@truncate(u1, op0 >> 3) == 0b0 and
            @truncate(u1, op0) == 0b0 and
            op1 <= 0b01 and
            @truncate(u3, op2) == 0b100 and
            @truncate(u7, op3 >> 7) == 0b00 and
            @truncate(u2, op3) == 0b10)
        { // SIMD two reg misc
            const u = @truncate(u1, op >> 29);
            const size = @truncate(u2, op >> 22);
            const opcode = @truncate(u5, op >> 12);
            return if (u == 0b0 and opcode == 0b00000) // SIMD two reg misc
                @as(Instruction, Instruction.rev64)
            else if (u == 0b0 and opcode == 0b00001)
                Instruction{ .rev16 = undefined }
            else if (u == 0b0 and opcode == 0b00010)
                @as(Instruction, Instruction.saddlp)
            else if (u == 0b0 and opcode == 0b00011)
                @as(Instruction, Instruction.suqadd)
            else if (u == 0b0 and opcode == 0b00100)
                Instruction{ .cls = undefined }
            else if (u == 0b0 and opcode == 0b00101)
                @as(Instruction, Instruction.cnt)
            else if (u == 0b0 and opcode == 0b00110)
                @as(Instruction, Instruction.sadalp)
            else if (u == 0b0 and opcode == 0b00111)
                @as(Instruction, Instruction.sqabs)
            else if (u == 0b0 and opcode == 0b01000)
                @as(Instruction, Instruction.cmgt)
            else if (u == 0b0 and opcode == 0b01001)
                @as(Instruction, Instruction.cmeq)
            else if (u == 0b0 and opcode == 0b01010)
                @as(Instruction, Instruction.cmlt)
            else if (u == 0b0 and opcode == 0b01011) blk: {
                const op_size = @truncate(u2, op >> 22);
                const q = @truncate(u1, op >> 30);
                const sizeq = @as(u3, op_size) << 1 | q;
                const payload = SIMDDataProcInstr{
                    .arrangement = @intToEnum(ArrangementTy, sizeq),
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                };
                break :blk Instruction{ .abs = payload };
            } else if (u == 0b0 and opcode == 0b10010)
                @as(Instruction, Instruction.xtn)
            else if (u == 0b0 and opcode == 0b10100)
                @as(Instruction, Instruction.sqxtn)
            else if (u == 0b0 and size <= 0b01 and opcode == 0b10110)
                @as(Instruction, Instruction.fcvtn)
            else if (u == 0b0 and size <= 0b01 and opcode == 0b10111)
                @as(Instruction, Instruction.fcvtl)
            else if (u == 0b0 and size <= 0b01 and opcode == 0b11000)
                Instruction{ .frintn = undefined }
            else if (u == 0b0 and size <= 0b01 and opcode == 0b11001)
                Instruction{ .frintm = undefined }
            else if (u == 0b0 and size <= 0b01 and opcode == 0b11010)
                Instruction{ .fcvtns = undefined }
            else if (u == 0b0 and size <= 0b01 and opcode == 0b11011)
                Instruction{ .fcvtms = undefined }
            else if (u == 0b0 and size <= 0b01 and opcode == 0b11100)
                Instruction{ .fcvtas = undefined }
            else if (u == 0b0 and size <= 0b01 and opcode == 0b11101)
                Instruction{ .scvtf = undefined }
            else if (u == 0b0 and size <= 0b01 and opcode == 0b11110)
                @as(Instruction, Instruction.frint32z)
            else if (u == 0b0 and size <= 0b01 and opcode == 0b11111)
                @as(Instruction, Instruction.frint64z)
            else if (u == 0b0 and size >= 0b10 and opcode == 0b01100)
                @as(Instruction, Instruction.fcmgt)
            else if (u == 0b0 and size >= 0b10 and opcode == 0b01101)
                @as(Instruction, Instruction.fcmeq)
            else if (u == 0b0 and size >= 0b10 and opcode == 0b01110)
                @as(Instruction, Instruction.fcmlt)
            else if (u == 0b0 and size >= 0b10 and opcode == 0b01111)
                Instruction{ .fabs = undefined }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b11000)
                Instruction{ .frintp = undefined }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b11001)
                Instruction{ .frintz = undefined }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b11010)
                Instruction{ .fcvtps = undefined }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b11011)
                Instruction{ .fcvtzs = undefined }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b11100)
                @as(Instruction, Instruction.urecpe)
            else if (u == 0b0 and size >= 0b10 and opcode == 0b11101)
                @as(Instruction, Instruction.frecpe)
            else if (u == 0b0 and size == 0b10 and opcode == 0b10110)
                @as(Instruction, Instruction.bfcvtn)
            else if (u == 0b1 and opcode == 0b00000)
                Instruction{ .rev32 = undefined }
            else if (u == 0b1 and opcode == 0b00010)
                @as(Instruction, Instruction.uaddlp)
            else if (u == 0b1 and opcode == 0b00011)
                @as(Instruction, Instruction.usqadd)
            else if (u == 0b1 and opcode == 0b00100)
                Instruction{ .clz = undefined }
            else if (u == 0b1 and opcode == 0b00110)
                @as(Instruction, Instruction.uadalp)
            else if (u == 0b1 and opcode == 0b00111)
                @as(Instruction, Instruction.sqneg)
            else if (u == 0b1 and opcode == 0b01000)
                @as(Instruction, Instruction.cmge)
            else if (u == 0b1 and opcode == 0b01001)
                @as(Instruction, Instruction.cmle)
            else if (u == 0b1 and opcode == 0b01011)
                @as(Instruction, Instruction.neg)
            else if (u == 0b1 and opcode == 0b10010)
                @as(Instruction, Instruction.sqxtun)
            else if (u == 0b1 and opcode == 0b10011)
                @as(Instruction, Instruction.shll)
            else if (u == 0b1 and opcode == 0b10100)
                @as(Instruction, Instruction.uqxtun)
            else if (u == 0b1 and size <= 0b01 and opcode == 0b10110)
                @as(Instruction, Instruction.fcvtxn)
            else if (u == 0b1 and size <= 0b01 and opcode == 0b11000)
                Instruction{ .frinta = undefined }
            else if (u == 0b1 and size <= 0b01 and opcode == 0b11001)
                Instruction{ .frintx = undefined }
            else if (u == 0b1 and size <= 0b01 and opcode == 0b11010)
                Instruction{ .fcvtnu = undefined }
            else if (u == 0b1 and size <= 0b01 and opcode == 0b11011)
                Instruction{ .fcvtmu = undefined }
            else if (u == 0b1 and size <= 0b01 and opcode == 0b11100)
                Instruction{ .fcvtau = undefined }
            else if (u == 0b1 and size <= 0b01 and opcode == 0b11101)
                Instruction{ .ucvtf = undefined }
            else if (u == 0b1 and size <= 0b01 and opcode == 0b11110)
                @as(Instruction, Instruction.frint32x)
            else if (u == 0b1 and size <= 0b01 and opcode == 0b11111)
                @as(Instruction, Instruction.frint64x)
            else if (u == 0b1 and size == 0b00 and opcode == 0b00101)
                @as(Instruction, Instruction.not)
            else if (u == 0b1 and size == 0b01 and opcode == 0b00101)
                Instruction{ .rbit = undefined }
            else if (u == 0b1 and size >= 0b10 and opcode == 0b01100)
                @as(Instruction, Instruction.fcmge)
            else if (u == 0b1 and size >= 0b10 and opcode == 0b01101)
                @as(Instruction, Instruction.fcmle)
            else if (u == 0b1 and size >= 0b10 and opcode == 0b01111)
                Instruction{ .fneg = undefined }
            else if (u == 0b1 and size >= 0b10 and opcode == 0b11001)
                Instruction{ .frinti = undefined }
            else if (u == 0b1 and size >= 0b10 and opcode == 0b11010)
                Instruction{ .fcvtpu = undefined }
            else if (u == 0b1 and size >= 0b10 and opcode == 0b11011)
                Instruction{ .fcvtzu = undefined }
            else if (u == 0b1 and size >= 0b10 and opcode == 0b11100)
                @as(Instruction, Instruction.ursqrte)
            else if (u == 0b1 and size >= 0b10 and opcode == 0b11101)
                @as(Instruction, Instruction.frsqrte)
            else if (u == 0b1 and size >= 0b10 and opcode == 0b11111)
                Instruction{ .fsqrt = undefined }
            else
                error.Unallocated;
        } else if (@truncate(u1, op0 >> 3) == 0b0 and
            @truncate(u1, op0) == 0b0 and
            op1 <= 0b01 and
            @truncate(u3, op2) == 0b110 and
            @truncate(u7, op3 >> 7) == 0b00 and
            @truncate(u2, op3) == 0b10)
        { // SIMD across lanes
            const u = @truncate(u1, op >> 29);
            const size = @truncate(u2, op >> 22);
            const opcode = @truncate(u5, op >> 12);
            const q = @truncate(u1, op >> 30);
            const sizeq = @as(u3, size) << 1 | q;
            return if (u == 0 and opcode == 0b00011)
                @as(Instruction, Instruction.saddlv)
            else if (u == 0 and opcode == 0b01010)
                @as(Instruction, Instruction.smaxv)
            else if (u == 0 and opcode == 0b11010)
                @as(Instruction, Instruction.sminv)
            else if (u == 0 and opcode == 0b11011) blk: {
                const width = if (size == 0b00)
                    Width.b
                else if (size == 0b01)
                    Width.h
                else if (size == 0b10)
                    Width.s
                else
                    return error.Unallocated;
                break :blk Instruction{ .addv = SIMDDataProcInstr{
                    .arrangement = if (sizeq != 0b100)
                        @intToEnum(ArrangementTy, sizeq)
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, Width.v, false),
                    .rd = Register.from(op, width, false),
                } };
            } else if (u == 0 and size == 0b00 and opcode == 0b01100)
                @as(Instruction, Instruction.fmaxnmv)
            else if (u == 0 and size == 0b00 and opcode == 0b01111)
                @as(Instruction, Instruction.fmaxv)
            else if (u == 0 and size == 0b10 and opcode == 0b01100)
                @as(Instruction, Instruction.fminnmv)
            else if (u == 0 and size == 0b10 and opcode == 0b01111)
                @as(Instruction, Instruction.fminv)
            else if (u == 1 and opcode == 0b00011)
                @as(Instruction, Instruction.uaddlv)
            else if (u == 1 and opcode == 0b01010)
                @as(Instruction, Instruction.umaxv)
            else if (u == 1 and opcode == 0b11010)
                @as(Instruction, Instruction.uminv)
            else if (u == 1 and size <= 0b01 and opcode == 0b01100)
                @as(Instruction, Instruction.fmaxnmv)
            else if (u == 1 and size <= 0b01 and opcode == 0b01111)
                @as(Instruction, Instruction.fmaxv)
            else if (u == 1 and size >= 0b10 and opcode == 0b01100)
                @as(Instruction, Instruction.fminnmv)
            else if (u == 1 and size >= 0b10 and opcode == 0b01111)
                @as(Instruction, Instruction.fminv)
            else
                error.Unimplemented;
        } else if (@truncate(u1, op0 >> 3) == 0b0 and
            @truncate(u1, op0) == 0b0 and
            op1 <= 0b01 and
            @truncate(u1, op2 >> 2) == 0b1 and
            @truncate(u2, op3) == 0b00)
        { // SIMD three different
            const u = @truncate(u1, op >> 29);
            const opcode = @truncate(u4, op >> 12);
            const size = @truncate(u2, op >> 22);
            const q = @truncate(u1, op >> 30);
            const sizeq = @as(u3, size) << 1 | q;
            const payload = SIMDDataProcInstr{
                .q = @truncate(u1, op >> 30) == 1,
                .arrangement = if (size != 0b11)
                    @intToEnum(ArrangementTy, sizeq)
                else
                    return error.Unallocated,
                .rm = Register.from(op >> 16, .v, false),
                .rn = Register.from(op >> 5, .v, false),
                .rd = Register.from(op, .v, false),
            };
            return if (u == 0 and opcode == 0b0000)
                @as(Instruction, Instruction.saddl)
            else if (u == 0 and opcode == 0b0001)
                @as(Instruction, Instruction.saddw)
            else if (u == 0 and opcode == 0b0010)
                @as(Instruction, Instruction.ssubl)
            else if (u == 0 and opcode == 0b0011)
                @as(Instruction, Instruction.ssubw)
            else if (u == 0 and opcode == 0b0100)
                Instruction{ .addhn = payload }
            else if (u == 0 and opcode == 0b0101)
                @as(Instruction, Instruction.sabal)
            else if (u == 0 and opcode == 0b0110)
                @as(Instruction, Instruction.subhn)
            else if (u == 0 and opcode == 0b0111)
                @as(Instruction, Instruction.sabdl)
            else if (u == 0 and opcode == 0b1000)
                @as(Instruction, Instruction.smlal)
            else if (u == 0 and opcode == 0b1001)
                @as(Instruction, Instruction.sqdmlal)
            else if (u == 0 and opcode == 0b1010)
                @as(Instruction, Instruction.smlsl)
            else if (u == 0 and opcode == 0b1011)
                @as(Instruction, Instruction.sqdmlsl)
            else if (u == 0 and opcode == 0b1100)
                @as(Instruction, Instruction.smull)
            else if (u == 0 and opcode == 0b1101)
                @as(Instruction, Instruction.sqdmull)
            else if (u == 0 and opcode == 0b1110)
                @as(Instruction, Instruction.pmull)
            else if (u == 1 and opcode == 0b0000)
                @as(Instruction, Instruction.uaddl)
            else if (u == 1 and opcode == 0b0001)
                @as(Instruction, Instruction.uaddw)
            else if (u == 1 and opcode == 0b0010)
                @as(Instruction, Instruction.usubl)
            else if (u == 1 and opcode == 0b0011)
                @as(Instruction, Instruction.usubw)
            else if (u == 1 and opcode == 0b0100)
                @as(Instruction, Instruction.raddhn)
            else if (u == 1 and opcode == 0b0101)
                @as(Instruction, Instruction.uabal)
            else if (u == 1 and opcode == 0b0110)
                @as(Instruction, Instruction.rsubhn)
            else if (u == 1 and opcode == 0b0111)
                @as(Instruction, Instruction.uabdl)
            else if (u == 1 and opcode == 0b1000)
                @as(Instruction, Instruction.umlal)
            else if (u == 1 and opcode == 0b1010)
                @as(Instruction, Instruction.umlsl)
            else if (u == 1 and opcode == 0b1100)
                @as(Instruction, Instruction.umull)
            else
                error.Unallocated;
        } else if (@truncate(u1, op0 >> 3) == 0b0 and
            @truncate(u1, op0) == 0b0 and
            op1 <= 0b01 and
            @truncate(u1, op2 >> 2) == 0b1 and
            @truncate(u1, op3) == 0b1)
        { // SIMD three same
            const u = @truncate(u1, op >> 29);
            const size = @truncate(u2, op >> 22);
            const opcode = @truncate(u5, op >> 11);
            const q = @truncate(u1, op >> 30);
            const sizeq = @as(u3, size) << 1 | q;
            const rm = Register.from(op >> 16, .v, false);
            const rn = Register.from(op >> 5, .v, false);
            const rd = Register.from(op, .v, false);
            return if (u == 0 and opcode == 0b00000)
                @as(Instruction, Instruction.shadd)
            else if (u == 0 and opcode == 0b00001)
                @as(Instruction, Instruction.sqadd)
            else if (u == 0 and opcode == 0b00010)
                @as(Instruction, Instruction.srhadd)
            else if (u == 0 and opcode == 0b00100)
                @as(Instruction, Instruction.shsub)
            else if (u == 0 and opcode == 0b00101)
                @as(Instruction, Instruction.sqsub)
            else if (u == 0 and opcode == 0b00110)
                @as(Instruction, Instruction.cmgt)
            else if (u == 0 and opcode == 0b00111)
                @as(Instruction, Instruction.cmge)
            else if (u == 0 and opcode == 0b01000)
                @as(Instruction, Instruction.sshl)
            else if (u == 0 and opcode == 0b01001)
                @as(Instruction, Instruction.sqshl)
            else if (u == 0 and opcode == 0b01010)
                @as(Instruction, Instruction.srshl)
            else if (u == 0 and opcode == 0b01011)
                @as(Instruction, Instruction.sqrshl)
            else if (u == 0 and opcode == 0b01100)
                @as(Instruction, Instruction.smax)
            else if (u == 0 and opcode == 0b01101)
                @as(Instruction, Instruction.smin)
            else if (u == 0 and opcode == 0b01110)
                @as(Instruction, Instruction.sabd)
            else if (u == 0 and opcode == 0b01111)
                @as(Instruction, Instruction.saba)
            else if (u == 0 and opcode == 0b10000)
                Instruction{ .vector_add = SIMDDataProcInstr{
                    .arrangement = @intToEnum(ArrangementTy, sizeq),
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b10001)
                @as(Instruction, Instruction.cmtst)
            else if (u == 0 and opcode == 0b10010)
                @as(Instruction, Instruction.mla)
            else if (u == 0 and opcode == 0b10011)
                @as(Instruction, Instruction.mul)
            else if (u == 0 and opcode == 0b10100)
                @as(Instruction, Instruction.smaxp)
            else if (u == 0 and opcode == 0b10101)
                @as(Instruction, Instruction.sminp)
            else if (u == 0 and opcode == 0b10110)
                @as(Instruction, Instruction.sqdmulh)
            else if (u == 0 and opcode == 0b10111)
                Instruction{ .addp = SIMDDataProcInstr{
                    .q = @truncate(u1, op >> 30) == 1,
                    .arrangement = if (sizeq != 0b110)
                        @intToEnum(ArrangementTy, sizeq)
                    else
                        return error.Unallocated,
                    .rm = Register.from(op >> 16, .v, false),
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                } }
            else if (u == 0 and size <= 0b01 and opcode == 0b11000)
                Instruction{ .fmaxnm = undefined }
            else if (u == 0 and size <= 0b01 and opcode == 0b11001)
                @as(Instruction, Instruction.fmla)
            else if (u == 0 and size <= 0b01 and opcode == 0b11010)
                Instruction{ .fadd = undefined }
            else if (u == 0 and size <= 0b01 and opcode == 0b11011)
                @as(Instruction, Instruction.fmulx)
            else if (u == 0 and size <= 0b01 and opcode == 0b11100)
                @as(Instruction, Instruction.fcmeq)
            else if (u == 0 and size <= 0b01 and opcode == 0b11110)
                Instruction{ .fmax = undefined }
            else if (u == 0 and size <= 0b01 and opcode == 0b11111)
                @as(Instruction, Instruction.frecps)
            else if (u == 0 and size == 0b00 and opcode == 0b00011)
                Instruction{ .@"and" = undefined }
            else if (u == 0 and size == 0b00 and opcode == 0b11101)
                @as(Instruction, Instruction.fmlal)
            else
                error.Unallocated;
        } else if (@truncate(u1, op0 >> 3) == 0b0 and
            @truncate(u1, op0) == 0b0 and
            op1 == 0b10 and
            op2 == 0b0000 and
            @truncate(u1, op3) == 0b1)
        {
            return error.Unimplemented; // SIMD modified immediate
        } else if (@truncate(u1, op0 >> 3) == 0b0 and
            @truncate(u1, op0) == 0b0 and
            op1 == 0b10 and
            op2 != 0b0000 and
            @truncate(u1, op3) == 0b1)
        {
            return error.Unimplemented; // SIMD shift by immediate
        } else if (@truncate(u1, op0 >> 3) == 0b0 and
            @truncate(u1, op0) == 0b0 and
            op1 >= 0b10 and
            @truncate(u1, op3) == 0b0)
        {
            return error.Unimplemented; // SIMD vector x indexed element
        } else if (op0 == 0b1100 and
            op1 == 0b00 and
            @truncate(u2, op2 >> 2) == 0b10 and
            @truncate(u2, op3 >> 4) == 0b10)
        {
            return error.Unimplemented; // Crypto three reg, imm2
        } else if (op0 == 0b1100 and
            op1 == 0b00 and
            @truncate(u2, op2 >> 2) == 0b11 and
            @truncate(u1, op3 >> 5) == 0b1 and
            @truncate(u2, op3 >> 2) == 0b00)
        {
            return error.Unimplemented; // Crypto three reg, sha512
        } else if (op0 == 0b1100 and
            op1 == 0b00 and
            @truncate(u1, op3 >> 5) == 0b1)
        {
            return error.Unimplemented; // Crypto four reg
        } else if (op0 == 0b1100 and
            op1 == 0b01 and
            @truncate(u2, op2 >> 2) == 0b00)
        {
            return error.Unimplemented; // Xar
        } else if (op0 == 0b1100 and
            op1 == 0b01 and
            op2 == 0b1000 and
            @truncate(u7, op3 >> 2) == 0b0001000)
        {
            return error.Unimplemented; // Crypto two reg, sha512
        } else if (@truncate(u1, op0 >> 2) == 0b0 and
            @truncate(u1, op0) == 0b1 and
            op1 <= 0b01 and
            @truncate(u1, op2 >> 2) == 0b0)
        {
            const sf = @truncate(u1, op >> 31);
            const s = @truncate(u1, op >> 29);
            const ptype = @truncate(u2, op >> 22);
            const rmode = @truncate(u2, op >> 19);
            const opcode = @truncate(u3, op >> 16);
            const scale = @truncate(u6, op >> 10);
            const rd_width = if (sf == 0b1) Width.x else Width.w;
            const rn_width = switch (ptype) {
                0b00 => Width.s,
                0b01 => Width.d,
                0b11 => Width.h,
                else => unreachable,
            };
            const to_fixed_payload = CvtInstr{
                .rd = Register.from(op, rd_width, false),
                .rn = Register.from(op >> 5, rn_width, false),
                .fbits = @truncate(u6, op >> 10),
            };
            const to_float_payload = CvtInstr{
                .rd = Register.from(op, rn_width, false),
                .rn = Register.from(op >> 5, rd_width, false),
                .fbits = @truncate(u6, op >> 10),
            };
            return if ((sf == 0b0 and scale <= 0b011111) or
                s == 0b1 or ptype == 0b10 or opcode >= 0b100 or
                (@truncate(u1, rmode) == 0b0 and @truncate(u2, opcode >> 1) == 0b00) or
                (@truncate(u1, rmode) == 0b1 and @truncate(u2, opcode >> 1) == 0b01) or
                (@truncate(u1, rmode >> 1) == 0b0 and @truncate(u2, opcode >> 1) == 0b00) or
                (@truncate(u1, rmode >> 1) == 0b1 and @truncate(u2, opcode >> 1) == 0b01))
                error.Unallocated
            else if (rmode == 0b11 and opcode == 0b001)
                Instruction{ .fcvtzu = to_fixed_payload }
            else if (rmode == 0b11 and opcode == 0b000)
                Instruction{ .fcvtzs = to_fixed_payload }
            else if (rmode == 0b00 and opcode == 0b011)
                Instruction{ .ucvtf = to_float_payload }
            else if (rmode == 0b00 and opcode == 0b010)
                Instruction{ .scvtf = to_float_payload }
            else
                error.Unallocated;
        } else if (@truncate(u1, op0 >> 2) == 0b0 and
            @truncate(u1, op0) == 0b1 and
            op1 <= 0b01 and
            @truncate(u1, op2 >> 2) == 0b1 and
            @truncate(u6, op3) == 0b000000)
        {
            const sf = @truncate(u1, op >> 31);
            const s = @truncate(u1, op >> 29);
            const ptype = @truncate(u2, op >> 22);
            const rmode = @truncate(u2, op >> 19);
            const opcode = @truncate(u3, op >> 16);
            return if ((@truncate(u1, rmode) == 0b1 and @truncate(u2, opcode >> 1) == 0b01) or
                (@truncate(u1, rmode) == 0b1 and @truncate(u2, opcode >> 1) == 0b10) or
                (@truncate(u1, rmode >> 1) == 0b1 and @truncate(u2, opcode >> 1) == 0b01) or
                (@truncate(u1, rmode >> 1) == 0b1 and @truncate(u2, opcode >> 1) == 0b10) or
                (s == 0b0 and ptype == 0b10 and @truncate(u1, opcode >> 2) == 0b0) or
                (s == 0b0 and ptype == 0b10 and @truncate(u2, opcode >> 1) == 0b10) or
                (s == 0b1) or
                (sf == 0b0 and s == 0b0 and ptype == 0b00 and @truncate(u1, rmode) == 0b1 and @truncate(u2, opcode >> 1) == 0b11) or
                (sf == 0b0 and s == 0b0 and ptype == 0b00 and @truncate(u1, rmode >> 1) == 0b1 and @truncate(u2, opcode >> 1) == 0b11) or
                (sf == 0b0 and s == 0b0 and ptype == 0b01 and @truncate(u1, rmode >> 1) == 0b0 and @truncate(u2, opcode >> 1) == 0b11) or
                (sf == 0b0 and s == 0b0 and ptype == 0b01 and rmode == 0b10 and @truncate(u2, opcode >> 1) == 0b11) or
                (sf == 0b0 and s == 0b0 and ptype == 0b01 and rmode == 0b11 and opcode == 0b111) or
                (sf == 0b0 and s == 0b0 and ptype == 0b10 and @truncate(u2, opcode >> 1) == 0b11) or
                (sf == 0b1 and s == 0b0 and ptype == 0b00 and @truncate(u2, opcode >> 1) == 0b11) or
                (sf == 0b1 and s == 0b0 and ptype == 0b01 and @truncate(u1, rmode) == 0b1 and @truncate(u2, opcode >> 1) == 0b11) or
                (sf == 0b1 and s == 0b0 and ptype == 0b01 and @truncate(u1, rmode >> 1) == 0b1 and @truncate(u2, opcode >> 1) == 0b11) or
                (sf == 0b1 and s == 0b0 and ptype == 0b10 and @truncate(u1, rmode) == 0b0 and @truncate(u2, opcode >> 1) == 0b11) or
                (sf == 0b1 and s == 0b0 and ptype == 0b10 and @truncate(u1, rmode >> 1) == 0b1 and @truncate(u2, opcode >> 1) == 0b11))
                error.Unallocated
            else if ((sf == 0b0 and ptype == 0b00 and rmode == 0b00 and opcode == 0b110) or
                (sf == 0b0 and ptype == 0b00 and rmode == 0b00 and opcode == 0b111) or
                (sf == 0b0 and ptype == 0b11 and rmode == 0b00 and opcode == 0b110) or
                (sf == 0b0 and ptype == 0b11 and rmode == 0b00 and opcode == 0b111) or
                (sf == 0b1 and ptype == 0b01 and rmode == 0b00 and opcode == 0b110) or
                (sf == 0b1 and ptype == 0b01 and rmode == 0b00 and opcode == 0b111) or
                (sf == 0b1 and ptype == 0b10 and rmode == 0b01 and opcode == 0b110) or
                (sf == 0b1 and ptype == 0b10 and rmode == 0b01 and opcode == 0b111) or
                (sf == 0b1 and ptype == 0b11 and rmode == 0b00 and opcode == 0b110) or
                (sf == 0b1 and ptype == 0b11 and rmode == 0b00 and opcode == 0b111))
            blk: {
                const mov_rd_width = if ((sf == 0b0 and ptype == 0b11 and rmode == 0b00 and opcode == 0b110) or
                    (sf == 0b0 and ptype == 0b00 and rmode == 0b00 and opcode == 0b110))
                    Width.w
                else if ((sf == 0b1 and ptype == 0b11 and rmode == 0b00 and opcode == 0b110) or
                    (sf == 0b1 and ptype == 0b01 and rmode == 0b00 and opcode == 0b110) or
                    (sf == 0b1 and ptype == 0b10 and rmode == 0b01 and opcode == 0b110))
                    Width.x
                else if ((sf == 0b0 and ptype == 0b11 and rmode == 0b00 and opcode == 0b111) or
                    (sf == 0b1 and ptype == 0b11 and rmode == 0b00 and opcode == 0b111))
                    Width.h
                else if (sf == 0b0 and ptype == 0b00 and rmode == 0b00 and opcode == 0b111)
                    Width.s
                else if (sf == 0b1 and ptype == 0b01 and rmode == 0b00 and opcode == 0b111)
                    Width.d
                else if (sf == 0b1 and ptype == 0b10 and rmode == 0b01 and opcode == 0b111)
                    Width.v
                else
                    unreachable;
                const mov_rs_width = if ((sf == 0b0 and ptype == 0b00 and rmode == 0b00 and opcode == 0b111) or
                    (sf == 0b0 and ptype == 0b11 and rmode == 0b00 and opcode == 0b111))
                    Width.w
                else if ((sf == 0b1 and ptype == 0b01 and rmode == 0b00 and opcode == 0b111) or
                    (sf == 0b1 and ptype == 0b10 and rmode == 0b01 and opcode == 0b111) or
                    (sf == 0b1 and ptype == 0b11 and rmode == 0b00 and opcode == 0b111))
                    Width.x
                else if ((sf == 0b0 and ptype == 0b11 and rmode == 0b00 and opcode == 0b110) or
                    (sf == 0b1 and ptype == 0b11 and rmode == 0b00 and opcode == 0b110))
                    Width.h
                else if (sf == 0b0 and ptype == 0b00 and rmode == 0b00 and opcode == 0b110)
                    Width.s
                else if (sf == 0b1 and ptype == 0b01 and rmode == 0b00 and opcode == 0b110)
                    Width.d
                else if (sf == 0b1 and ptype == 0b10 and rmode == 0b01 and opcode == 0b110)
                    Width.v
                else
                    unreachable;
                const payload = FMovInstr{
                    .rd = Register.from(op, mov_rd_width, false),
                    .payload = .{ .rs = Register.from(op >> 5, mov_rs_width, false) },
                };
                break :blk Instruction{ .fmov = payload };
            } else blk: {
                const rd_width = if (sf == 0b1) Width.x else Width.w;
                const rn_width = switch (ptype) {
                    0b00 => Width.s,
                    0b01 => Width.d,
                    0b11 => Width.h,
                    else => unreachable,
                };
                const to_fixed_payload = CvtInstr{
                    .rd = Register.from(op, rd_width, false),
                    .rn = Register.from(op >> 5, rn_width, false),
                    .fbits = null,
                };
                const to_float_payload = CvtInstr{
                    .rd = Register.from(op, rn_width, false),
                    .rn = Register.from(op >> 5, rd_width, false),
                    .fbits = null,
                };
                break :blk if (rmode == 0b00 and opcode == 0b101)
                    Instruction{ .fcvtau = to_fixed_payload }
                else if (rmode == 0b00 and opcode == 0b100)
                    Instruction{ .fcvtas = to_fixed_payload }
                else if (rmode == 0b11 and opcode == 0b001)
                    Instruction{ .fcvtzu = to_fixed_payload }
                else if (rmode == 0b11 and opcode == 0b000)
                    Instruction{ .fcvtzs = to_fixed_payload }
                else if (rmode == 0b10 and opcode == 0b001)
                    Instruction{ .fcvtmu = to_fixed_payload }
                else if (rmode == 0b10 and opcode == 0b000)
                    Instruction{ .fcvtms = to_fixed_payload }
                else if (rmode == 0b01 and opcode == 0b001)
                    Instruction{ .fcvtpu = to_fixed_payload }
                else if (rmode == 0b01 and opcode == 0b000)
                    Instruction{ .fcvtps = to_fixed_payload }
                else if (rmode == 0b00 and opcode == 0b001)
                    Instruction{ .fcvtnu = to_fixed_payload }
                else if (rmode == 0b00 and opcode == 0b000)
                    Instruction{ .fcvtns = to_fixed_payload }
                else if (sf == 0b0 and ptype == 0b01 and rmode == 0b11 and opcode == 0b110)
                    @as(Instruction, Instruction.fjcvtzs)
                else if (rmode == 0b00 and opcode == 0b011)
                    Instruction{ .ucvtf = to_float_payload }
                else if (rmode == 0b00 and opcode == 0b010)
                    Instruction{ .scvtf = to_float_payload }
                else
                    error.Unallocated;
            };
        } else if (@truncate(u1, op0 >> 2) == 0b0 and
            @truncate(u1, op0) == 0b1 and
            op1 <= 0b01 and
            @truncate(u1, op2 >> 2) == 0b1 and
            @truncate(u5, op3) == 0b10000)
        {
            const m = @truncate(u1, op >> 31);
            const s = @truncate(u1, op >> 29);
            const ptype = @truncate(u2, op >> 22);
            const opcode = @truncate(u6, op >> 15);
            const ftype_width = switch (ptype) {
                0b00 => Width.s,
                0b01 => Width.d,
                0b11 => Width.h,
                else => unreachable,
            };
            const opc_width = switch (@truncate(u2, opcode)) {
                0b00 => Width.s,
                0b01 => Width.d,
                0b11 => Width.h,
                else => null,
            };
            const single_data_payload = DataProcInstr{
                .rn = Register.from(op >> 5, ftype_width, false),
                .rd = Register.from(op, ftype_width, false),
            };
            return if (m == 0b1 or s == 0b1 or ptype == 0b10 or opcode >= 0b100000)
                error.Unallocated
            else if (opcode == 0b000000) blk: {
                const payload = FMovInstr{
                    .rd = Register.from(op, ftype_width, false),
                    .payload = .{ .rs = Register.from(op >> 5, ftype_width, false) },
                };
                break :blk Instruction{ .fmov = payload };
            } else if (opcode == 0b000001)
                Instruction{ .fabs = single_data_payload }
            else if (opcode == 0b000010)
                Instruction{ .fneg = single_data_payload }
            else if (opcode == 0b000011)
                Instruction{ .fsqrt = single_data_payload }
            else if ((ptype == 0b00 and opcode == 0b000101) or
                (ptype == 0b00 and opcode == 0b000111) or
                (ptype == 0b01 and opcode == 0b000100) or
                (ptype == 0b01 and opcode == 0b000111) or
                (ptype == 0b11 and opcode == 0b000100) or
                (ptype == 0b11 and opcode == 0b000101))
            blk: {
                const payload = DataProcInstr{
                    .rn = Register.from(op >> 5, ftype_width, false),
                    .rd = Register.from(op, opc_width.?, false),
                };
                break :blk Instruction{ .fcvt = payload };
            } else if (opcode == 0b001000)
                Instruction{ .frintn = single_data_payload }
            else if (opcode == 0b001001)
                Instruction{ .frintp = single_data_payload }
            else if (opcode == 0b001010)
                Instruction{ .frintm = single_data_payload }
            else if (opcode == 0b001011)
                Instruction{ .frintz = single_data_payload }
            else if (opcode == 0b001100)
                Instruction{ .frinta = single_data_payload }
            else if (opcode == 0b001110)
                Instruction{ .frintx = single_data_payload }
            else if (opcode == 0b001111)
                Instruction{ .frinti = single_data_payload }
            else if (ptype <= 0b01 and opcode == 0b010000)
                @as(Instruction, Instruction.frint32z)
            else if (ptype <= 0b01 and opcode == 0b010001)
                @as(Instruction, Instruction.frint32x)
            else if (ptype <= 0b01 and opcode == 0b010010)
                @as(Instruction, Instruction.frint64z)
            else if (ptype <= 0b01 and opcode == 0b010011)
                @as(Instruction, Instruction.frint64x)
            else if (ptype == 0b01 and opcode == 0b000110)
                @as(Instruction, Instruction.bfcvt)
            else
                error.Unallocated;
        } else if (@truncate(u1, op0 >> 2) == 0b0 and
            @truncate(u1, op0) == 0b1 and
            op1 <= 0b01 and
            @truncate(u1, op2 >> 2) == 0b1 and
            @truncate(u4, op3) == 0b1000)
        {
            const m = @truncate(u1, op >> 31);
            const s = @truncate(u1, op >> 29);
            const ftype = @truncate(u2, op >> 22);
            const o1 = @truncate(u2, op >> 14);
            const opc = @truncate(u1, op >> 3);
            const opcode2 = @truncate(u5, op);
            const e = opcode2 == 0b10000 or opcode2 == 0b11000;
            const width = if (ftype == 0b11)
                Width.h
            else if (ftype == 0b00)
                Width.s
            else if (ftype == 0b01)
                Width.d
            else
                return error.Unallocated;
            const rm = Register.from(op >> 16, width, false);
            const FPCompPayload = Field(FPCompInstr, .payload);
            const rm_or_zero = if (opc == 0b1)
                @as(FPCompPayload, FPCompPayload.zero)
            else
                FPCompPayload{ .rm = rm };
            const payload = FPCompInstr{
                .e = e,
                .rn = Register.from(op >> 5, width, false),
                .payload = rm_or_zero,
            };
            return if (m == 0b1 or s == 0b1 or ftype == 0b10 or o1 != 0b00 or @truncate(u3, opcode2) != 0b00)
                error.Unallocated
            else
                Instruction{ .fcmp = payload };
        } else if (@truncate(u1, op0 >> 2) == 0b0 and
            @truncate(u1, op0) == 0b1 and
            op1 <= 0b01 and
            @truncate(u1, op2 >> 2) == 0b1 and
            @truncate(u3, op3) == 0b100)
        {
            const m = @truncate(u1, op >> 31);
            const s = @truncate(u1, op >> 29);
            const ptype = @truncate(u2, op >> 22);
            const imm5 = @truncate(u5, op >> 5);
            const imm8 = @truncate(u8, op >> 13);
            const a = @truncate(u1, imm8 >> 7);
            const b = @truncate(u1, imm8 >> 6);
            const c = @truncate(u1, imm8 >> 5);
            const d = @truncate(u1, imm8 >> 4);
            const e = @truncate(u1, imm8 >> 3);
            const f = @truncate(u1, imm8 >> 2);
            const g = @truncate(u1, imm8 >> 1);
            const h = @truncate(u1, imm8);
            const rd_width = switch (ptype) {
                0b00 => Width.s,
                0b01 => Width.d,
                0b11 => Width.h,
                else => unreachable,
            };
            const fp_const = switch (rd_width) {
                .h => @floatCast(f64, @bitCast(f16, 0 |
                    @as(u16, a) << 15 |
                    @as(u16, ~b) << 14 |
                    @as(u16, b) << 13 |
                    @as(u16, b) << 12 |
                    @as(u16, c) << 11 |
                    @as(u16, d) << 10 |
                    @as(u16, e) << 9 |
                    @as(u16, f) << 8 |
                    @as(u16, g) << 7 |
                    @as(u16, h) << 6)),
                .s => @floatCast(f64, @bitCast(f32, 0 |
                    @as(u32, a) << 31 |
                    @as(u32, ~b) << 30 |
                    @as(u32, b) << 29 |
                    @as(u32, b) << 28 |
                    @as(u32, b) << 27 |
                    @as(u32, b) << 26 |
                    @as(u32, b) << 25 |
                    @as(u32, c) << 24 |
                    @as(u32, d) << 23 |
                    @as(u32, e) << 22 |
                    @as(u32, f) << 21 |
                    @as(u32, g) << 20 |
                    @as(u32, h) << 19)),
                .d => @bitCast(f64, 0 |
                    @as(u64, a) << 63 |
                    @as(u64, ~b) << 62 |
                    @as(u64, b) << 61 |
                    @as(u64, b) << 60 |
                    @as(u64, b) << 59 |
                    @as(u64, b) << 58 |
                    @as(u64, b) << 57 |
                    @as(u64, b) << 56 |
                    @as(u64, b) << 55 |
                    @as(u64, b) << 54 |
                    @as(u64, c) << 53 |
                    @as(u64, d) << 52 |
                    @as(u64, e) << 51 |
                    @as(u64, f) << 50 |
                    @as(u64, g) << 49 |
                    @as(u64, h) << 48),
                else => unreachable,
            };
            const payload = FMovInstr{
                .rd = Register.from(op, rd_width, false),
                .payload = .{ .fp_const = fp_const },
            };
            return if (m != 0b1 and s != 0b1 and imm5 == 0b00000)
                Instruction{ .fmov = payload }
            else
                error.Unallocated;
        } else if (@truncate(u1, op0 >> 2) == 0b0 and
            @truncate(u1, op0) == 0b1 and
            op1 <= 0b01 and
            @truncate(u1, op2 >> 2) == 0b1 and
            @truncate(u2, op3) == 0b01)
        {
            const m = @truncate(u1, op >> 31);
            const s = @truncate(u1, op >> 29);
            const ftype = @truncate(u2, op >> 22);
            const o1 = @truncate(u1, op >> 4);
            const width = if (ftype == 0b11)
                Width.h
            else if (ftype == 0b00)
                Width.s
            else if (ftype == 0b01)
                Width.d
            else
                return error.Unallocated;
            const payload = FPCondCompInstr{
                .e = o1 == 0b1,
                .rn = Register.from(op >> 5, width, false),
                .rm = Register.from(op >> 16, width, false),
                .nzcv = @truncate(u4, op),
                .cond = @intToEnum(Condition, @truncate(u4, op >> 12)),
            };
            return if (m == 0b1 or s == 0b1 or ftype == 0b10)
                error.Unallocated
            else
                Instruction{ .fccmp = payload };
        } else if (@truncate(u1, op0 >> 2) == 0b0 and
            @truncate(u1, op0) == 0b1 and
            op1 <= 0b01 and
            @truncate(u1, op2 >> 2) == 0b1 and
            @truncate(u2, op3) == 0b10)
        {
            const m = @truncate(u1, op >> 31);
            const s = @truncate(u1, op >> 29);
            const ptype = @truncate(u2, op >> 22);
            const opcode = @truncate(u4, op >> 12);
            const width = switch (ptype) {
                0b00 => Width.s,
                0b01 => Width.d,
                0b11 => Width.h,
                else => unreachable,
            };
            const payload = DataProcInstr{
                .rn = Register.from(op >> 5, width, false),
                .rd = Register.from(op, width, false),
                .rm = Register.from(op >> 16, width, false),
            };
            return if (m == 0b1 or s == 0b1 or ptype == 0b10)
                error.Unallocated
            else if (opcode == 0b0000)
                Instruction{ .fmul = payload }
            else if (opcode == 0b0001)
                Instruction{ .fdiv = payload }
            else if (opcode == 0b0010)
                Instruction{ .fadd = payload }
            else if (opcode == 0b0011)
                Instruction{ .fsub = payload }
            else if (opcode == 0b0100)
                Instruction{ .fmax = payload }
            else if (opcode == 0b0101)
                Instruction{ .fmin = payload }
            else if (opcode == 0b0110)
                Instruction{ .fmaxnm = payload }
            else if (opcode == 0b0111)
                Instruction{ .fminnm = payload }
            else if (opcode == 0b1000)
                Instruction{ .fnmul = payload }
            else
                error.Unallocated;
        } else if (@truncate(u1, op0 >> 2) == 0b0 and
            @truncate(u1, op0) == 0b1 and
            op1 <= 0b01 and
            @truncate(u1, op2 >> 2) == 0b1 and
            @truncate(u2, op3) == 0b11)
        {
            const m = @truncate(u1, op >> 31);
            const s = @truncate(u1, op >> 29);
            const ftype = @truncate(u2, op >> 22);
            const width = if (ftype == 0b11)
                Width.h
            else if (ftype == 0b00)
                Width.s
            else if (ftype == 0b01)
                Width.d
            else
                return error.Unallocated;
            const payload = FPCondSelInstr{
                .rn = Register.from(op >> 5, width, false),
                .rd = Register.from(op, width, false),
                .rm = Register.from(op >> 16, width, false),
                .cond = @intToEnum(Condition, @truncate(u4, op >> 12)),
            };
            return if (m == 0b1 or s == 0b1 or ftype == 0b10)
                error.Unallocated
            else
                Instruction{ .fcsel = payload };
        } else if (@truncate(u1, op0 >> 2) == 0b0 and @truncate(u1, op0) == 0b1 and op1 >= 0b10) {
            const m = @truncate(u1, op >> 31);
            const s = @truncate(u1, op >> 29);
            const ptype = @truncate(u2, op >> 22);
            const o1 = @truncate(u1, op >> 21);
            const o0 = @truncate(u1, op >> 15);
            const width = switch (ptype) {
                0b00 => Width.s,
                0b01 => Width.d,
                0b11 => Width.h,
                else => unreachable,
            };
            const payload = DataProcInstr{
                .rn = Register.from(op >> 5, width, false),
                .rd = Register.from(op, width, false),
                .rm = Register.from(op >> 16, width, false),
                .ra = Register.from(op >> 10, width, false),
            };
            return if (m == 0b1 or s == 0b1 or ptype == 0b10)
                error.Unallocated
            else if (o1 == 0b0 and o0 == 0b0)
                Instruction{ .fmadd = payload }
            else if (o1 == 0b0 and o0 == 0b1)
                Instruction{ .fmsub = payload }
            else if (o1 == 0b1 and o0 == 0b0)
                Instruction{ .fnmadd = payload }
            else if (o1 == 0b1 and o0 == 0b1)
                Instruction{ .fnmsub = payload }
            else
                error.Unallocated;
        } else return error.Unallocated;
    }
};
