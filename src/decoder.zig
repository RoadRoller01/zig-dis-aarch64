const std = @import("std");
const utils = @import("utils.zig");
const Register = utils.Register;
const Width = utils.Width;
const Field = utils.Field;
const matches = utils.matches;

const SIMDArrangement = @import("instruction.zig").SIMDArrangement;
const AddSubInstr = @import("instruction.zig").AddSubInstr;
const AesInstr = @import("instruction.zig").AesInstr;
const BitfieldInstr = @import("instruction.zig").BitfieldInstr;
const BranchCondInstr = @import("instruction.zig").BranchCondInstr;
const BranchInstr = @import("instruction.zig").BranchInstr;
const CompBranchInstr = @import("instruction.zig").CompBranchInstr;
const ConCompInstr = @import("instruction.zig").ConCompInstr;
const ConSelectInstr = @import("instruction.zig").ConSelectInstr;
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
const SIMDLoadStoreInstr = @import("instruction.zig").SIMDLoadStoreInstr;
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

        const op = reader.readInt(u32, .little) catch return null;

        const op0 = op >> 31;
        const op1 = @as(u4, @truncate(op >> 25));

        switch (op1) {
            0b0000 => return if (op0 == 0) try decodeReserve(op) else try decodeSME(op), // Reserved and SME
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
        const op0 = @as(u3, @truncate(op >> 23));

        return switch (op0) {
            0b000, 0b001 => blk: {
                const p = op >> 31 == 1;
                const payload = PCRelAddrInstr{
                    .p = p,
                    .rd = Register.from(op, .x, false),
                    .immhi = @as(u19, @truncate(op >> 5)),
                    .immlo = @as(u2, @truncate(op >> 29)),
                };
                break :blk if (p)
                    Instruction{ .adrp = payload }
                else
                    Instruction{ .adr = payload };
            },
            0b010 => blk: {
                const s = @as(u1, @truncate(op >> 29)) == 1;
                const op1 = @as(u1, @truncate(op >> 30));
                const width = Width.from(op >> 31);
                const payload = AddSubInstr{
                    .s = s,
                    .op = if (op1 == 0) .add else .sub,
                    .width = width,
                    .rn = Register.from(op >> 5, width, true),
                    .rd = Register.from(op, width, !s),
                    .payload = .{ .imm12 = .{
                        .sh = @as(u1, @truncate(op >> 22)),
                        .imm = @as(u12, @truncate(op >> 10)),
                    } },
                };
                break :blk if (op1 == 0)
                    Instruction{ .add = payload }
                else
                    Instruction{ .sub = payload };
            },
            0b011 => blk: {
                const o2 = @as(u1, @truncate(op >> 2));
                const sf = @as(u1, @truncate(op >> 31));
                const s = @as(u1, @truncate(op >> 29)) == 1;
                const add = @as(u1, @truncate(op >> 30)) == 0;
                const payload = AddSubInstr{
                    .s = s,
                    .op = if (add) .add else .sub,
                    .width = .x,
                    .rn = Register.from(op >> 5, .x, s),
                    .rd = Register.from(op, .x, s),
                    .payload = .{ .imm_tag = .{
                        .imm6 = @as(u6, @truncate(op >> 16)),
                        .imm4 = @as(u4, @truncate(op >> 10)),
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
                const n = @as(u1, @truncate(op >> 22));
                const opc = @as(u2, @truncate(op >> 29));
                // TODO: stage1 moment
                const LogTy = Field(LogInstr, .op);
                const log_op = switch (opc) {
                    0b00, 0b11 => LogTy.@"and",
                    0b01 => LogTy.orr,
                    0b10 => LogTy.eor,
                };
                const payload = LogInstr{
                    .s = opc == 0b11,
                    .n = @as(u1, @truncate(op >> 22)),
                    .op = log_op,
                    .width = width,
                    .rn = Register.from(op >> 5, width, false),
                    .rd = Register.from(op, width, true),
                    .payload = .{ .imm = .{
                        .immr = @as(u6, @truncate(op >> 16)),
                        .imms = @as(u6, @truncate(op >> 10)),
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
                const opc = @as(u2, @truncate(op >> 29));
                const hw = @as(u2, @truncate(op >> 21));
                const imm16 = @as(u16, @truncate(op >> 5));
                const ext: Field(MovInstr, .ext) = if (opc == 0b00)
                    if (imm16 == 0x0000 and @as(u1, @truncate(hw >> 1)) != 0b0)
                        .none
                    else
                        .n
                else if (opc == 0b10)
                    if (imm16 == 0x0000 and !(width == .x or @as(u1, @truncate(hw >> 1)) == 0b0))
                        .none
                    else
                        .z
                else if (opc == 0b11)
                    .k
                else
                    break :blk error.Unallocated;
                break :blk if (width == .w and (hw == 0b10 or hw == 0b11))
                    error.Unallocated
                else
                    .{ .mov = .{
                        .ext = ext,
                        .width = width,
                        .hw = hw,
                        .imm16 = imm16,
                        .rd = Register.from(op, width, false),
                    } };
            },
            0b110 => blk: {
                const opc = @as(u2, @truncate(op >> 29));
                const n = @as(u1, @truncate(op >> 22));
                const ext: Field(BitfieldInstr, .ext) = @enumFromInt(opc);
                const immr = @as(u6, @truncate(op >> 16));
                const imms = @as(u6, @truncate(op >> 10));
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
                        .immr = @as(u6, @truncate(op >> 16)),
                        .imms = @as(u6, @truncate(op >> 10)),
                        .rn = Register.from(op >> 5, rn_width, false),
                        .rd = Register.from(op, rd_width, false),
                    } };
            },
            0b111 => blk: {
                const width = Width.from(op >> 31);
                const op21 = @as(u2, @truncate(op >> 29));
                const n = @as(u1, @truncate(op >> 22));
                const o0 = @as(u1, @truncate(op >> 21));
                const imms = @as(u6, @truncate(op >> 10));
                break :blk if (op21 != 0b00 or
                    (op21 == 0b00 and o0 == 1) or
                    (@intFromEnum(width) == 0 and imms >= 0b100000) or
                    (@intFromEnum(width) == 0 and n == 1) or
                    (@intFromEnum(width) == 1 and n == 0))
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
        const op0 = @as(u3, @truncate(op >> 29));
        const op1 = @as(u14, @truncate(op >> 12));
        const op2 = @as(u5, @truncate(op));

        if (op0 == 0b010 and matches(op1, "0b0xxxxxxxxxxxxx")) {
            const o0 = @as(u1, @truncate(op >> 4));
            const o1 = @as(u1, @truncate(op >> 24));
            const payload = BranchCondInstr{
                .imm19 = @as(u19, @truncate(op >> 5)),
                .cond = @enumFromInt(@as(u4, @truncate(op))),
            };
            return if (o0 == 0b0 and o1 == 0b0)
                Instruction{ .bcond = payload }
            else if (o0 == 0b1 and o1 == 0b0)
                Instruction{ .bccond = payload }
            else
                error.Unallocated;
        } else if (op0 == 0b110 and matches(op1, "0b00xxxxxxxxxxxx")) {
            const opc = @as(u3, @truncate(op >> 21));
            const opc2 = @as(u3, @truncate(op >> 2));
            const ll = @as(u2, @truncate(op));
            const payload = ExceptionInstr{ .imm16 = @as(u16, @truncate(op >> 5)) };
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
            const crm = @as(u4, @truncate(op >> 8));
            const o2 = @as(u3, @truncate(op >> 5));
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
            const crm = @as(u4, @truncate(op >> 8));
            const o2 = @as(u3, @truncate(op >> 5));
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
            else if (crm == 0b0100 and @as(u1, @truncate(o2)) == 0b0)
                @as(Instruction, Instruction.bti)
            else
                .{ .hint = .{ .imm = @as(u7, crm) << 3 | op2 } };
        } else if (op0 == 0b110 and op1 == 0b01000000110011) {
            const crm = @as(u4, @truncate(op >> 8));
            const opc2 = @as(u3, @truncate(op >> 5));
            const rt = @as(u5, @truncate(op));
            return if (opc2 == 0b010 and rt == 0b11111)
                Instruction{ .clrex = @as(u4, @truncate(op >> 8)) }
            else if (opc2 == 0b100 and rt == 0b11111)
                Instruction{ .dsb = @as(u4, @truncate(op >> 8)) }
            else if (opc2 == 0b101 and rt == 0b11111)
                Instruction{ .dmb = @as(u4, @truncate(op >> 8)) }
            else if (opc2 == 0b110 and rt == 0b11111)
                Instruction{ .isb = @as(u4, @truncate(op >> 8)) }
            else if (opc2 == 0b111 and rt == 0b11111)
                @as(Instruction, Instruction.sb)
            else if (@as(u2, @truncate(crm)) == 0b10 and opc2 == 0b001 and rt == 0b11111)
                Instruction{ .dsb = @as(u4, @truncate(op >> 8)) }
            else if (crm == 0b0000 and opc2 == 0b011 and rt == 0b11111)
                @as(Instruction, Instruction.tcommit)
            else
                error.Unallocated;
        } else if (op0 == 0b110 and matches(op1, "0b0100000xxx0100")) {
            const instr1 = @as(u3, @truncate(op >> 16));
            const instr2 = @as(u3, @truncate(op >> 5));
            const rt = @as(u5, @truncate(op));
            return if (instr1 == 0b000 and instr2 == 0b000 and rt == 0b11111)
                @as(Instruction, Instruction.cfinv)
            else if (instr1 == 0b000 and instr2 == 0b001 and rt == 0b11111)
                @as(Instruction, Instruction.xaflag)
            else if (instr1 == 0b000 and instr2 == 0b010 and rt == 0b11111)
                @as(Instruction, Instruction.axflag)
            else if (rt == 0b11111) blk: {
                const payload = SysRegMoveInstr{
                    .rt = Register.from(op, .x, false),
                    .op2 = @as(u3, @truncate(op >> 5)),
                    .crm = @as(u4, @truncate(op >> 8)),
                    .crn = @as(u4, @truncate(op >> 12)),
                    .op1 = @as(u3, @truncate(op >> 16)),
                    .o0 = @as(u1, @truncate(op >> 19)),
                    .o20 = @as(u1, @truncate(op >> 20)),
                    .op = .write,
                };
                break :blk Instruction{ .msr = payload };
            } else error.Unallocated;
        } else if (op0 == 0b110 and matches(op1, "0b0100100xxxxxxx")) {
            const o1 = @as(u3, @truncate(op >> 16));
            const crn = @as(u4, @truncate(op >> 12));
            const crm = @as(u4, @truncate(op >> 8));
            const o2 = @as(u3, @truncate(op >> 5));
            const payload = SysWithResInstr{ .rt = Register.from(op, .x, false) };
            return if (o1 == 0b011 and crn == 0b0011 and crm == 0b0000 and o2 == 0b011)
                Instruction{ .tstart = payload }
            else if (o1 == 0b011 and crn == 0b0011 and crm == 0b0000 and o2 == 0b011)
                Instruction{ .ttest = payload }
            else
                error.Unallocated;
        } else if (op0 == 0b110 and matches(op1, "0b0100x01xxxxxxx")) {
            const l = @as(u1, @truncate(op >> 21)) == 1;
            const payload = SysInstr{
                .l = l,
                .rt = Register.from(op, .x, false),
                .op2 = @as(u3, @truncate(op >> 5)),
                .crm = @as(u4, @truncate(op >> 8)),
                .crn = @as(u4, @truncate(op >> 12)),
                .op1 = @as(u3, @truncate(op >> 16)),
            };
            return Instruction{ .sys = payload };
        } else if (op0 == 0b110 and matches(op1, "0b0100x1xxxxxxxx")) {
            const l = @as(u1, @truncate(op >> 21)) == 1;
            const payload = SysRegMoveInstr{
                .rt = Register.from(op, .x, false),
                .op2 = @as(u3, @truncate(op >> 5)),
                .crm = @as(u4, @truncate(op >> 8)),
                .crn = @as(u4, @truncate(op >> 12)),
                .op1 = @as(u3, @truncate(op >> 16)),
                .o0 = @as(u1, @truncate(op >> 19)),
                .o20 = @as(u1, @truncate(op >> 20)),
                .op = if (l) .write else .read,
            };
            return if (l)
                Instruction{ .mrs = payload }
            else
                Instruction{ .msr = payload };
        } else if (op0 == 0b110 and matches(op1, "0b1xxxxxxxxxxxxx")) {
            const opc = @as(u4, @truncate(op >> 21));
            const o2 = @as(u5, @truncate(op >> 16));
            const o3 = @as(u6, @truncate(op >> 10));
            const o4 = @as(u5, @truncate(op));
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
            const o = @as(u1, @truncate(op >> 31));
            const payload = BranchInstr{ .imm = @as(u26, @truncate(op)) };
            return if (o == 0)
                Instruction{ .b = payload }
            else
                Instruction{ .bl = payload };
        } else if (matches(op0, "0bx01") and matches(op1, "0b0xxxxxxxxxxxxx")) {
            const width = Width.from(op >> 31);
            const neg = @as(u1, @truncate(op >> 24)) == 1;
            const payload = CompBranchInstr{
                .imm19 = @as(u19, @truncate(op >> 5)),
                .rt = Register.from(op, width, false),
            };
            return if (neg)
                Instruction{ .cbnz = payload }
            else
                Instruction{ .cbz = payload };
        } else if (matches(op0, "0bx01") and matches(op1, "0b1xxxxxxxxxxxxx")) {
            const o = @as(u1, @truncate(op >> 24));
            const payload = TestInstr{
                .b5 = @as(u1, @truncate(op >> 31)),
                .b40 = @as(u5, @truncate(op >> 19)),
                .imm14 = @as(u14, @truncate(op >> 5)),
                .rt = Register.from(op, .x, false),
            };
            return if (o == 0)
                Instruction{ .tbz = payload }
            else
                Instruction{ .tbnz = payload };
        } else return error.Unallocated;
    }

    fn decodeLoadStore(op: u32) Error!Instruction {
        const op0 = @as(u4, @truncate(op >> 28));
        const op1 = @as(u1, @truncate(op >> 26));
        const op2 = @as(u2, @truncate(op >> 23));
        const op3 = @as(u6, @truncate(op >> 16));
        const op4 = @as(u2, @truncate(op >> 10));
        const ExtTy = Field(LoadStoreInstr, .ext);
        const OpTy = Field(LoadStoreInstr, .op);
        const SizeTy = Field(LoadStoreInstr, .size);
        const LdStPayloadTy = Field(LoadStoreInstr, .payload);
        const IndexTy = @typeInfo(Field(LoadStoreInstr, .index)).optional.child;
        const LdStPrfm = Field(LoadStoreInstr, .ld_st_prfm);
        if (matches(op0, "0b0x00") and op1 == 0b1 and op2 == 0b00 and matches(op3, "0b1xxxxx"))
            return error.Unimplemented // Compare and swap pair
        else if (matches(op0, "0b0x00") and op1 == 1 and op2 == 0b00 and op3 == 0b00000) { // Advanced SIMD load/store multiple structures
            const l = @as(u1, @truncate(op >> 22));
            const opcode = @as(u4, @truncate(op >> 12));
            const t = @as(u5, @truncate(op));
            const rn = Register.from(op >> 5, .x, true);
            const rt = Register.from(t, .v, false);
            const rt2 = Register.from((t + 1) % 31, .v, false);
            const rt3 = Register.from((t + 2) % 31, .v, false);
            const rt4 = Register.from((t + 3) % 31, .v, false);
            const size = @as(u2, @truncate(op >> 10));
            const q = @as(u1, @truncate(op >> 30));
            const sizeq = @as(u3, size) << 1 | q;
            return if (l == 0b0 and opcode == 0b0000)
                Instruction{ .st4 = SIMDLoadStoreInstr{
                    .arrangement = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                } }
            else if (l == 0b0 and opcode == 0b0010)
                Instruction{ .st1 = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                } }
            else if (l == 0b0 and opcode == 0b0100)
                Instruction{ .st3 = SIMDLoadStoreInstr{
                    .arrangement = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                } }
            else if (l == 0b0 and opcode == 0b0110)
                Instruction{ .st1 = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                } }
            else if (l == 0b0 and opcode == 0b0111)
                Instruction{ .st1 = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                } }
            else if (l == 0b0 and opcode == 0b1000)
                Instruction{ .st2 = SIMDLoadStoreInstr{
                    .arrangement = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                } }
            else if (l == 0b0 and opcode == 0b1010)
                Instruction{ .st1 = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                } }
            else if (l == 0b1 and opcode == 0b0000)
                Instruction{ .ld4 = SIMDLoadStoreInstr{
                    .arrangement = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                } }
            else if (l == 0b1 and opcode == 0b0010)
                Instruction{ .ld1 = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                } }
            else if (l == 0b1 and opcode == 0b0100)
                Instruction{ .ld3 = SIMDLoadStoreInstr{
                    .arrangement = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                } }
            else if (l == 0b1 and opcode == 0b0110)
                Instruction{ .ld1 = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                } }
            else if (l == 0b1 and opcode == 0b0111)
                Instruction{ .ld1 = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                } }
            else if (l == 0b1 and opcode == 0b1000)
                Instruction{ .ld2 = SIMDLoadStoreInstr{
                    .arrangement = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                } }
            else if (l == 0b1 and opcode == 0b1010)
                Instruction{ .ld1 = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                } }
            else
                error.Unallocated;
        } else if (matches(op0, "0b0x00") and op1 == 1 and op2 == 0b01 and matches(op3, "0b0xxxxx")) { // Advanced SIMD load/store multiple structures (post-indexed)
            const l = @as(u1, @truncate(op >> 22));
            const m = @as(u5, @truncate(op >> 16));
            const t = @as(u5, @truncate(op));
            const opcode = @as(u4, @truncate(op >> 12));
            const rn = Register.from(op >> 5, .x, true);
            const rt = Register.from(t, .v, false);
            const rt2 = Register.from((t + 1) % 31, .v, false);
            const rt3 = Register.from((t + 2) % 31, .v, false);
            const rt4 = Register.from((t + 3) % 31, .v, false);
            const rm = Register.from(m, .x, false);
            const size = @as(u2, @truncate(op >> 10));
            const q = @as(u1, @truncate(op >> 30));
            const sizeq = @as(u3, size) << 1 | q;
            return if (l == 0b0 and opcode == 0b0000)
                Instruction{ .st4 = SIMDLoadStoreInstr{
                    .arrangement = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = (@as(u7, q) + 1) * 32 },
                } }
            else if (l == 0b0 and opcode == 0b0010)
                Instruction{ .st1 = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = (@as(u7, q) + 1) * 32 },
                } }
            else if (l == 0b0 and opcode == 0b0100)
                Instruction{ .st3 = SIMDLoadStoreInstr{
                    .arrangement = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = (@as(u7, q) + 1) * 24 },
                } }
            else if (l == 0b0 and opcode == 0b0110)
                Instruction{ .st1 = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = (@as(u7, q) + 1) * 24 },
                } }
            else if (l == 0b0 and opcode == 0b0111)
                Instruction{ .st1 = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = (@as(u7, q) + 1) * 8 },
                } }
            else if (l == 0b0 and opcode == 0b1000)
                Instruction{ .st2 = SIMDLoadStoreInstr{
                    .arrangement = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = (@as(u7, q) + 1) * 16 },
                } }
            else if (l == 0b0 and opcode == 0b1010)
                Instruction{ .st1 = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = (@as(u7, q) + 1) * 16 },
                } }
            else if (l == 0b1 and opcode == 0b0000)
                Instruction{ .ld4 = SIMDLoadStoreInstr{
                    .arrangement = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = (@as(u7, q) + 1) * 32 },
                } }
            else if (l == 0b1 and opcode == 0b0010)
                Instruction{ .ld1 = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = (@as(u7, q) + 1) * 32 },
                } }
            else if (l == 0b1 and opcode == 0b0100)
                Instruction{ .ld3 = SIMDLoadStoreInstr{
                    .arrangement = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = (@as(u7, q) + 1) * 24 },
                } }
            else if (l == 0b1 and opcode == 0b0110)
                Instruction{ .ld1 = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = (@as(u7, q) + 1) * 24 },
                } }
            else if (l == 0b1 and opcode == 0b0111)
                Instruction{ .ld1 = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = (@as(u7, q) + 1) * 8 },
                } }
            else if (l == 0b1 and opcode == 0b1000)
                Instruction{ .ld2 = SIMDLoadStoreInstr{
                    .arrangement = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = (@as(u7, q) + 1) * 16 },
                } }
            else if (l == 0b1 and opcode == 0b1010)
                Instruction{ .ld1 = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = (@as(u7, q) + 1) * 16 },
                } }
            else
                error.Unimplemented;
        } else if (matches(op0, "0b0x00") and op1 == 1 and op2 == 0b10 and matches(op3, "0bx00000")) { // Advanced SIMD load/store single structure (post-indexed)
            const l = @as(u1, @truncate(op >> 22));
            const r = @as(u1, @truncate(op >> 21));
            const opcode = @as(u3, @truncate(op >> 13));
            const s = @as(u1, @truncate(op >> 12));
            const size = @as(u2, @truncate(op >> 10));
            const t = @as(u5, @truncate(op));
            const rn = Register.from(op >> 5, .x, true);
            const rt = Register.from(t, .v, false);
            const rt2 = Register.from((t + 1) % 31, .v, false);
            const rt3 = Register.from((t + 2) % 31, .v, false);
            const rt4 = Register.from((t + 3) % 31, .v, false);
            const q = @as(u1, @truncate(op >> 30));
            const sizeq = @as(u3, size) << 1 | q;
            return if (l == 0b0 and r == 0b0 and opcode == 0b000)
                Instruction{ .st1 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.b,
                    .rn = rn,
                    .rt = rt,
                    .index = @as(u4, q) << 3 | @as(u4, s) << 2 | size,
                } }
            else if (l == 0b0 and r == 0b0 and opcode == 0b001)
                Instruction{ .st3 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.b,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .index = @as(u4, q) << 3 | @as(u4, s) << 2 | size,
                } }
            else if (l == 0b0 and r == 0b0 and opcode == 0b010 and @as(u1, @truncate(size)) == 0b0)
                Instruction{ .st1 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.h,
                    .rn = rn,
                    .rt = rt,
                    .index = @as(u3, q) << 2 | @as(u3, s) << 1 | @as(u1, @truncate(size >> 1)),
                } }
            else if (l == 0b0 and r == 0b0 and opcode == 0b011 and @as(u1, @truncate(size)) == 0b0)
                Instruction{ .st3 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.h,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .index = @as(u3, q) << 2 | @as(u3, s) << 1 | @as(u1, @truncate(size >> 1)),
                } }
            else if (l == 0b0 and r == 0b0 and opcode == 0b100 and size == 0b00)
                Instruction{ .st1 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.s,
                    .rn = rn,
                    .rt = rt,
                    .index = @as(u2, q) << 1 | s,
                } }
            else if (l == 0b0 and r == 0b0 and opcode == 0b100 and s == 0b0 and size == 0b01)
                Instruction{ .st1 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.d,
                    .rn = rn,
                    .rt = rt,
                    .index = q,
                } }
            else if (l == 0b0 and r == 0b0 and opcode == 0b101 and size == 0b00)
                Instruction{ .st3 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.s,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .index = @as(u2, q) << 1 | s,
                } }
            else if (l == 0b0 and r == 0b0 and opcode == 0b101 and s == 0b0 and size == 0b01)
                Instruction{ .st3 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.d,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .index = q,
                } }
            else if (l == 0b0 and r == 0b1 and opcode == 0b000)
                Instruction{ .st2 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.b,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .index = @as(u4, q) << 3 | @as(u4, s) << 2 | size,
                } }
            else if (l == 0b0 and r == 0b1 and opcode == 0b001)
                Instruction{ .st4 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.b,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .index = @as(u4, q) << 3 | @as(u4, s) << 2 | size,
                } }
            else if (l == 0b0 and r == 0b1 and opcode == 0b010 and @as(u1, @truncate(size)) == 0b0)
                Instruction{ .st2 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.h,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .index = @as(u3, q) << 2 | @as(u3, s) << 1 | @as(u1, @truncate(size >> 1)),
                } }
            else if (l == 0b0 and r == 0b1 and opcode == 0b011 and @as(u1, @truncate(size)) == 0b0)
                Instruction{ .st4 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.h,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .index = @as(u3, q) << 2 | @as(u3, s) << 1 | @as(u1, @truncate(size >> 1)),
                } }
            else if (l == 0b0 and r == 0b1 and opcode == 0b100 and size == 0b00)
                Instruction{ .st2 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.s,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .index = @as(u2, q) << 1 | s,
                } }
            else if (l == 0b0 and r == 0b1 and opcode == 0b100 and s == 0b0 and size == 0b01)
                Instruction{ .st2 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.d,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .index = q,
                } }
            else if (l == 0b0 and r == 0b1 and opcode == 0b101 and size == 0b00)
                Instruction{ .st4 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.s,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .index = @as(u2, q) << 1 | s,
                } }
            else if (l == 0b0 and r == 0b1 and opcode == 0b101 and s == 0b0 and size == 0b01)
                Instruction{ .st4 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.d,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .index = q,
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b000)
                Instruction{ .ld1 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.b,
                    .rn = rn,
                    .rt = rt,
                    .index = @as(u4, q) << 3 | @as(u4, s) << 2 | size,
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b001)
                Instruction{ .ld3 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.b,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .index = @as(u4, q) << 3 | @as(u4, s) << 2 | size,
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b010 and @as(u1, @truncate(size)) == 0b0)
                Instruction{ .ld1 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.h,
                    .rn = rn,
                    .rt = rt,
                    .index = @as(u3, q) << 2 | @as(u3, s) << 1 | @as(u1, @truncate(size >> 1)),
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b011 and @as(u1, @truncate(size)) == 0b0)
                Instruction{ .ld3 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.h,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .index = @as(u3, q) << 2 | @as(u3, s) << 1 | @as(u1, @truncate(size >> 1)),
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b100 and size == 0b00)
                Instruction{ .ld1 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.s,
                    .rn = rn,
                    .rt = rt,
                    .index = @as(u2, q) << 1 | s,
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b100 and s == 0b0 and size == 0b01)
                Instruction{ .ld1 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.d,
                    .rn = rn,
                    .rt = rt,
                    .index = q,
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b101 and size == 0b00)
                Instruction{ .ld3 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.s,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .index = @as(u2, q) << 1 | s,
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b101 and s == 0b0 and size == 0b01)
                Instruction{ .ld3 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.d,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .index = q,
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b110 and s == 0b0)
                Instruction{ .ld1r = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b111 and s == 0b0)
                Instruction{ .ld3r = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b000)
                Instruction{ .ld2 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.b,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .index = @as(u4, q) << 3 | @as(u4, s) << 2 | size,
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b001)
                Instruction{ .ld4 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.b,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .index = @as(u4, q) << 3 | @as(u4, s) << 2 | size,
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b010 and @as(u1, @truncate(size)) == 0b0)
                Instruction{ .ld2 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.h,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .index = @as(u3, q) << 2 | @as(u3, s) << 1 | @as(u1, @truncate(size >> 1)),
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b011 and @as(u1, @truncate(size)) == 0b0)
                Instruction{ .ld4 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.h,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .index = @as(u3, q) << 2 | @as(u3, s) << 1 | @as(u1, @truncate(size >> 1)),
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b100 and size == 0b00)
                Instruction{ .ld2 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.s,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .index = @as(u2, q) << 1 | s,
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b100 and s == 0b0 and size == 0b01)
                Instruction{ .ld2 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.d,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .index = q,
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b101 and size == 0b00)
                Instruction{ .ld4 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.s,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .index = @as(u2, q) << 1 | s,
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b101 and s == 0b0 and size == 0b01)
                Instruction{ .ld4 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.d,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .index = q,
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b110 and s == 0b0)
                Instruction{ .ld2r = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b111 and s == 0b0)
                Instruction{ .ld4r = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                } }
            else
                error.Unallocated;
        } else if (matches(op0, "0b0x00") and op1 == 1 and op2 == 0b11) { // Advanced SIMD load/store single structure (post-indexed)
            const l = @as(u1, @truncate(op >> 22));
            const r = @as(u1, @truncate(op >> 21));
            const s = @as(u1, @truncate(op >> 12));
            const size = @as(u2, @truncate(op >> 10));
            const m = @as(u5, @truncate(op >> 16));
            const t = @as(u5, @truncate(op));
            const opcode = @as(u3, @truncate(op >> 13));
            const rn = Register.from(op >> 5, .x, true);
            const rt = Register.from(t, .v, false);
            const rt2 = Register.from((t + 1) % 31, .v, false);
            const rt3 = Register.from((t + 2) % 31, .v, false);
            const rt4 = Register.from((t + 3) % 31, .v, false);
            const rm = Register.from(m, .x, false);
            const q = @as(u1, @truncate(op >> 30));
            const sizeq = @as(u3, size) << 1 | q;
            return if (l == 0b0 and r == 0b0 and opcode == 0b000)
                Instruction{ .st1 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.b,
                    .rn = rn,
                    .rt = rt,
                    .index = @as(u4, q) << 3 | @as(u4, s) << 2 | size,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 1 },
                } }
            else if (l == 0b0 and r == 0b0 and opcode == 0b001)
                Instruction{ .st3 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.b,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .index = @as(u4, q) << 3 | @as(u4, s) << 2 | size,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 3 },
                } }
            else if (l == 0b0 and r == 0b0 and opcode == 0b010 and @as(u1, @truncate(size)) == 0b0)
                Instruction{ .st1 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.h,
                    .rn = rn,
                    .rt = rt,
                    .index = @as(u3, q) << 2 | @as(u3, s) << 1 | @as(u1, @truncate(size >> 1)),
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 2 },
                } }
            else if (l == 0b0 and r == 0b0 and opcode == 0b011 and @as(u1, @truncate(size)) == 0b0)
                Instruction{ .st3 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.h,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .index = @as(u3, q) << 2 | @as(u3, s) << 1 | @as(u1, @truncate(size >> 1)),
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 6 },
                } }
            else if (l == 0b0 and r == 0b0 and opcode == 0b100 and size == 0b00)
                Instruction{ .st1 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.s,
                    .rn = rn,
                    .rt = rt,
                    .index = @as(u2, q) << 1 | s,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 4 },
                } }
            else if (l == 0b0 and r == 0b0 and opcode == 0b100 and s == 0b0 and size == 0b01)
                Instruction{ .st1 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.d,
                    .rn = rn,
                    .rt = rt,
                    .index = q,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 8 },
                } }
            else if (l == 0b0 and r == 0b0 and opcode == 0b101 and size == 0b00)
                Instruction{ .st3 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.s,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .index = @as(u2, q) << 1 | s,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 12 },
                } }
            else if (l == 0b0 and r == 0b0 and opcode == 0b101 and s == 0b0 and size == 0b01)
                Instruction{ .st3 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.d,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .index = q,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 24 },
                } }
            else if (l == 0b0 and r == 0b1 and opcode == 0b000)
                Instruction{ .st2 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.b,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .index = @as(u4, q) << 3 | @as(u4, s) << 2 | size,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 2 },
                } }
            else if (l == 0b0 and r == 0b1 and opcode == 0b001)
                Instruction{ .st4 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.b,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .index = @as(u4, q) << 3 | @as(u4, s) << 2 | size,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 4 },
                } }
            else if (l == 0b0 and r == 0b1 and opcode == 0b010 and @as(u1, @truncate(size)) == 0b0)
                Instruction{ .st2 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.h,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .index = @as(u3, q) << 2 | @as(u3, s) << 1 | @as(u1, @truncate(size >> 1)),
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 4 },
                } }
            else if (l == 0b0 and r == 0b1 and opcode == 0b011 and @as(u1, @truncate(size)) == 0b0)
                Instruction{ .st4 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.h,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .index = @as(u3, q) << 2 | @as(u3, s) << 1 | @as(u1, @truncate(size >> 1)),
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 8 },
                } }
            else if (l == 0b0 and r == 0b1 and opcode == 0b100 and size == 0b00)
                Instruction{ .st2 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.s,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .index = @as(u2, q) << 1 | s,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 8 },
                } }
            else if (l == 0b0 and r == 0b1 and opcode == 0b100 and s == 0b0 and size == 0b01)
                Instruction{ .st2 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.d,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .index = q,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 16 },
                } }
            else if (l == 0b0 and r == 0b1 and opcode == 0b101 and size == 0b00)
                Instruction{ .st4 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.s,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .index = @as(u2, q) << 1 | s,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 16 },
                } }
            else if (l == 0b0 and r == 0b1 and opcode == 0b101 and s == 0b0 and size == 0b01)
                Instruction{ .st4 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.d,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .index = q,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 32 },
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b000)
                Instruction{ .ld1 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.b,
                    .rn = rn,
                    .rt = rt,
                    .index = @as(u4, q) << 3 | @as(u4, s) << 2 | size,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 1 },
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b001)
                Instruction{ .ld3 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.b,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .index = @as(u4, q) << 3 | @as(u4, s) << 2 | size,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 3 },
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b010 and @as(u1, @truncate(size)) == 0b0)
                Instruction{ .ld1 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.h,
                    .rn = rn,
                    .rt = rt,
                    .index = @as(u3, q) << 2 | @as(u3, s) << 1 | @as(u1, @truncate(size >> 1)),
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 2 },
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b011 and @as(u1, @truncate(size)) == 0b0)
                Instruction{ .ld3 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.h,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .index = @as(u3, q) << 2 | @as(u3, s) << 1 | @as(u1, @truncate(size >> 1)),
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 6 },
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b100 and size == 0b00)
                Instruction{ .ld1 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.s,
                    .rn = rn,
                    .rt = rt,
                    .index = @as(u2, q) << 1 | s,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 4 },
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b100 and s == 0b0 and size == 0b01)
                Instruction{ .ld1 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.d,
                    .rn = rn,
                    .rt = rt,
                    .index = q,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 8 },
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b101 and size == 0b00)
                Instruction{ .ld3 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.s,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .index = @as(u2, q) << 1 | s,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 12 },
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b101 and s == 0b0 and size == 0b01)
                Instruction{ .ld3 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.d,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .index = q,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 24 },
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b110 and s == 0b0)
                Instruction{ .ld1r = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = @as(u7, 0b1) << size },
                } }
            else if (l == 0b1 and r == 0b0 and opcode == 0b111 and s == 0b0)
                Instruction{ .ld3r = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = @as(u7, 0b11) << size },
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b000)
                Instruction{ .ld2 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.b,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .index = @as(u4, q) << 3 | @as(u4, s) << 2 | size,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 2 },
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b001)
                Instruction{ .ld4 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.b,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .index = @as(u4, q) << 3 | @as(u4, s) << 2 | size,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 4 },
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b010 and @as(u1, @truncate(size)) == 0b0)
                Instruction{ .ld2 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.h,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .index = @as(u3, q) << 2 | @as(u3, s) << 1 | @as(u1, @truncate(size >> 1)),
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 4 },
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b011 and @as(u1, @truncate(size)) == 0b0)
                Instruction{ .ld4 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.h,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .index = @as(u3, q) << 2 | @as(u3, s) << 1 | @as(u1, @truncate(size >> 1)),
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 8 },
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b100 and size == 0b00)
                Instruction{ .ld2 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.s,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .index = @as(u2, q) << 1 | s,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 8 },
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b100 and s == 0b0 and size == 0b01)
                Instruction{ .ld2 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.d,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .index = q,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 16 },
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b101 and size == 0b00)
                Instruction{ .ld4 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.s,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .index = @as(u2, q) << 1 | s,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 16 },
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b101 and s == 0b0 and size == 0b01)
                Instruction{ .ld4 = SIMDLoadStoreInstr{
                    .arrangement = SIMDArrangement.d,
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .index = q,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = 32 },
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b110 and s == 0b0)
                Instruction{ .ld2r = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = @as(u7, 0b10) << size },
                } }
            else if (l == 0b1 and r == 0b1 and opcode == 0b111 and s == 0b0)
                Instruction{ .ld4r = SIMDLoadStoreInstr{
                    .arrangement = @enumFromInt(sizeq),
                    .rn = rn,
                    .rt = rt,
                    .rt2 = rt2,
                    .rt3 = rt3,
                    .rt4 = rt4,
                    .payload = if (m != 0b11111) .{ .rm = rm } else .{ .imm = @as(u7, 0b100) << size },
                } }
            else
                error.Unallocated;
        } else if (op0 == 0b1101 and op1 == 0 and matches(op2, "0b1x") and matches(op3, "0b1xxxxx")) // Load/store memory tags
            return error.Unimplemented
        else if (matches(op0, "0b1x00") and op1 == 0 and op2 == 0b00 and matches(op3, "0b1xxxxx")) { // Load/store exclusive pair
            const width = Width.from(op >> 30);
            const load = @as(u1, @truncate(op >> 22)) == 1;
            const o0 = @as(u1, @truncate(op >> 15)) == 1;
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
        } else if (matches(op0, "0bxx00") and op1 == 0 and op2 == 0b00 and matches(op3, "0b0xxxxx")) { // Load/store exclusive register
            const reg_size = @as(u2, @truncate(op >> 30));
            const load = @as(u1, @truncate(op >> 22)) == 1;
            const o0 = @as(u1, @truncate(op >> 15)) == 1;
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
        } else if (matches(op0, "0bxx00") and op1 == 0 and op2 == 0b01 and matches(op3, "0b0xxxxx")) { // Load/store ordered
            const reg_size = @as(u2, @truncate(op >> 30));
            const load = @as(u1, @truncate(op >> 22)) == 1;
            const o0 = @as(u1, @truncate(op >> 15)) == 1;
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
        } else if (matches(op0, "0bxx00") and op1 == 0 and op2 == 0b01 and matches(op3, "0b1xxxxx")) // Compare and swap
            return error.Unimplemented
        else if (matches(op0, "0bxx01") and op1 == 0 and matches(op2, "0b1x") and matches(op3, "0b0xxxxx") and op4 == 0b00) {
            const reg_size = @as(u2, @truncate(op >> 30));
            const opc = @as(u2, @truncate(op >> 22));
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
                .payload = .{ .simm9 = @as(u9, @truncate(op >> 12)) },
            };
            return if ((reg_size == 0b10 and opc == 0b11) or (reg_size == 0b11 and opc >= 0b10))
                error.Unallocated
            else if (ld_st == .ld)
                Instruction{ .ld = payload }
            else
                Instruction{ .st = payload };
        } else if (matches(op0, "0bxx01") and matches(op2, "0b0x")) { // Load register (literal)
            const opc = @as(u2, @truncate(op >> 30));
            const v = @as(u1, @truncate(op >> 26));
            const width = switch (@as(u3, opc) << 1 | v) {
                0b000, 0b110 => Width.w,
                0b001 => Width.s,
                0b010, 0b100 => Width.x,
                0b011 => Width.d,
                0b101 => Width.q,
                else => return error.Unallocated,
            };
            const size_ext = if (opc == 0b10 and v == 0) SizeTy.sw else SizeTy.none;
            const imm19 = @as(u19, @truncate(op >> 5));
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
        } else if (matches(op0, "0bxx01") and matches(op2, "0b1x") and matches(op3, "0b0xxxxx") and op4 == 0b01) // Memory Copy and Memory Set
            return error.Unimplemented
        else if (matches(op0, "0bxx10") and op2 == 0b00) { // Load/store no-allocate pair (offset)
            const opc = @as(u2, @truncate(op >> 30));
            const v = @as(u1, @truncate(op >> 26));
            const load = @as(u1, @truncate(op >> 22)) == 1;
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
            var simm7 = @as(i64, @intCast(@as(i7, @bitCast(@as(u7, @truncate(op >> 15))))));
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
        } else if (matches(op0, "0bxx10") and op2 != 0b00) { // Load/store register pair
            const opc = @as(u2, @truncate(op >> 30));
            const v = @as(u1, @truncate(op >> 26));
            const load = @as(u1, @truncate(op >> 22)) == 1;
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
            var simm7 = @as(i64, @intCast(@as(i7, @bitCast(@as(u7, @truncate(op >> 15))))));
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
        } else if (matches(op0, "0bxx11") and matches(op2, "0b0x") and matches(op3, "0b0xxxxx")) { // Load/store register
            const size = @as(u2, @truncate(op >> 30));
            const v = @as(u1, @truncate(op >> 26));
            const opc = @as(u2, @truncate(op >> 22));
            const load = switch (@as(u3, @truncate(op >> 26)) << 2 | @as(u2, @truncate(op >> 22))) {
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
                .payload = .{ .simm9 = @as(u9, @truncate(op >> 12)) },
                .index = index,
            };
            return if ((@as(u1, @truncate(size)) == 1 and v == 1 and opc >= 0b10) or
                (size >= 0b10 and v == 0 and opc == 0b11) or
                (size >= 0b10 and v == 1 and opc >= 0b10))
                error.Unallocated
            else if (size == 0b11 and v == 0 and opc == 0b10)
                Instruction{ .prfm = payload }
            else if (load)
                Instruction{ .ld = payload }
            else
                Instruction{ .st = payload };
        } else if (matches(op0, "0bxx11") and matches(op2, "0b0x") and matches(op3, "0b1xxxxx") and op4 == 0b00) { // Atomic memory operations
            return error.Unimplemented;
        } else if (matches(op0, "0bxx11") and matches(op2, "0b0x") and matches(op3, "0b1xxxxx") and op4 == 0b10) { // Load/store register (register offset)
            const size = @as(u2, @truncate(op >> 30));
            const v = @as(u1, @truncate(op >> 26));
            const opc = @as(u2, @truncate(op >> 22));
            const option = @as(u3, @truncate(op >> 13));
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
            const rm_width = if (@as(u1, @truncate(option)) == 0)
                Width.w
            else
                Width.x;
            const shift_not_zero = @as(u1, @truncate(op >> 12)) == 1;
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
            const shift = LdStPayloadTy{
                .shifted_reg = .{
                    .rm = Register.from(op >> 16, rm_width, false),
                    .shift = shift_not_zero,
                    .amount = amount,
                    .shift_type = @enumFromInt(
                        // Field(Field(LdStPayloadTy, .shifted_reg), .shift_type),
                        option,
                    ),
                },
            };
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
        } else if (matches(op0, "0bxx11") and matches(op2, "0b0x") and matches(op3, "0b1xxxxx") and matches(op4, "0bx1")) { // Load/store register (pac)
            // TODO
            const load = true;
            const payload = undefined;
            return if (load)
                Instruction{ .ld = payload }
            else
                Instruction{ .st = payload };
        } else if (matches(op0, "0bxx11") and matches(op2, "0b1x")) { // Load/store register (unsigned immediate)
            const v = @as(u1, @truncate(op >> 26));
            const opc = @as(u2, @truncate(op >> 22));
            const size = @as(u2, @truncate(op >> 30));
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
            var imm12 = @as(u12, @truncate(op >> 10));
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
            return if ((@as(u1, @truncate(size)) == 0b1 and v == 1 and opc >= 0b10) or
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
        const op0 = @as(u1, @truncate(op >> 30));
        const op1 = @as(u1, @truncate(op >> 28));
        const op2 = @as(u4, @truncate(op >> 21));
        const op3 = @as(u6, @truncate(op >> 10));
        _ = op0;

        // TODO: refactor to use return on top if (fixed in stage2)
        // https://github.com/ziglang/zig/issues/10601
        return if (op1 == 0) switch (op2) {
            0b0000...0b0111 => blk: { // logical shifted reg
                const imm6 = @as(u6, @truncate(op >> 10));
                const opc = @as(u2, @truncate(op >> 29));
                const width = Width.from(op >> 31);
                const n = @as(u1, @truncate(op >> 21));
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
                    .n = @as(u1, @truncate(op >> 21)),
                    .op = log_op,
                    .width = width,
                    // TODO: check sp
                    .rn = Register.from(op >> 5, width, false),
                    .rd = Register.from(op, width, false),
                    .payload = .{ .shift_reg = .{
                        .rm = Register.from(op >> 16, width, false),
                        .imm6 = imm6,
                        .shift = @as(u2, @truncate(op >> 22)),
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
                const s = @as(u1, @truncate(op >> 29)) == 1;
                const add = @as(u1, @truncate(op >> 30)) == 0;
                const payload = AddSubInstr{
                    .s = s,
                    .op = if (add) .add else .sub,
                    .width = width,
                    .rn = Register.from(op >> 5, width, false),
                    .rd = Register.from(op, width, false),
                    .payload = .{ .shift_reg = .{
                        .rm = Register.from(op >> 16, width, false),
                        .imm6 = @as(u6, @truncate(op >> 10)),
                        .shift = @as(u2, @truncate(op >> 22)),
                    } },
                };
                break :blk if (add)
                    Instruction{ .add = payload }
                else
                    Instruction{ .sub = payload };
            },

            0b1001, 0b1011, 0b1101, 0b1111 => blk: { // add/sub extended reg
                const width = Width.from(op >> 31);
                const s = @as(u1, @truncate(op >> 29)) == 1;
                const add = @as(u1, @truncate(op >> 30)) == 0;
                const opt = @as(u2, @truncate(op >> 22));
                const imm3 = @as(u3, @truncate(op >> 10));
                const payload = AddSubInstr{
                    .s = s,
                    .op = if (add) .add else .sub,
                    .width = width,
                    .rn = Register.from(op >> 5, width, true),
                    .rd = Register.from(op, width, !s),
                    .payload = .{ .ext_reg = .{
                        .rm = Register.from(op >> 16, width, false),
                        .option = @as(u3, @truncate(op >> 13)),
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
        } else switch (op2) {
            0b0000 => switch (op3) {
                0b000000 => {
                    const adc = @as(u1, @truncate(op >> 30)) == 0;
                    const width = Width.from(op >> 31);
                    const payload = AddSubInstr{
                        .s = @as(u1, @truncate(op >> 29)) == 1,
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
                const reg = @as(u1, @truncate(op >> 11)) == 0;
                const width = Width.from(op >> 31);
                const o3 = @as(u1, @truncate(op >> 4));
                const o2 = @as(u1, @truncate(op >> 10));
                const s = @as(u1, @truncate(op >> 29));
                const cmn = @as(u1, @truncate(op >> 30)) == 0;
                const payload = ConCompInstr{
                    .cond = @enumFromInt(@as(u4, @truncate(op >> 12))),
                    .rn = Register.from(op >> 5, width, false),
                    .nzcv = @as(u4, @truncate(op)),
                    .payload = if (reg) .{
                        .rm = Register.from(op >> 16, width, false),
                    } else .{ .imm5 = @as(u5, @truncate(op >> 16)) },
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
                const s = @as(u1, @truncate(op >> 29));
                const o = @as(u1, @truncate(op >> 30));
                const o2 = @as(u2, @truncate(op >> 10));
                const payload = ConSelectInstr{
                    .rm = Register.from(op >> 16, width, false),
                    .cond = @enumFromInt(@as(u4, @truncate(op >> 12))),
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
                const one_source = @as(u1, @truncate(op >> 30)) == 1;
                const opcode = @as(u6, @truncate(op >> 10));
                const s = @as(u1, @truncate(op >> 29));
                const payload = DataProcInstr{
                    // TODO: check for sp
                    .rm = if (!one_source) Register.from(op >> 16, width, false) else null,
                    .rn = Register.from(op >> 5, width, false),
                    .rd = Register.from(op, width, false),
                };
                return if (one_source) blk: {
                    const opcode2 = @as(u5, @truncate(op >> 16));
                    const rn = @as(u5, @truncate(op >> 5));
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
                const op54 = @as(u2, @truncate(op >> 29));
                const op31 = @as(u3, @truncate(op >> 21));
                const o0 = @as(u1, @truncate(op >> 15));
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
        const op0 = @as(u4, @truncate(op >> 28));
        const op1 = @as(u2, @truncate(op >> 23));
        const op2 = @as(u4, @truncate(op >> 19));
        const op3 = @as(u9, @truncate(op >> 10));
        // TODO: stage 1 moment
        const ShaOpTy = Field(ShaInstr, .op);
        const AesOpTy = Field(AesInstr, .op);
        // TODO: should be a top return
        if (op0 == 0b0100 and matches(op1, "0b0x") and matches(op2, "0bx101") and matches(op3, "0b00xxxxx10")) {
            const aes_op = switch (@as(u5, @truncate(op >> 12))) {
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
            return if (@as(u2, @truncate(op >> 22)) != 0b00)
                error.Unimplemented
            else
                Instruction{ .aes = payload };
        } else if (op0 == 0b0101 and matches(op1, "0b0x") and matches(op2, "0bx0xx") and matches(op3, "0bxxx0xxx00")) {
            const sha_op = switch (@as(u5, @as(u2, @truncate(op >> 22))) << 3 | @as(u3, @truncate(op >> 12))) {
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
        } else if (op0 == 0b0101 and matches(op1, "0b0x") and matches(op2, "0bx101") and matches(op3, "0b00xxxxx10")) {
            const sha_op = switch (@as(u7, @as(u2, @truncate(op >> 22))) << 3 | @as(u5, @truncate(op >> 12))) {
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
        } else if (matches(op0, "0b01x1") and matches(op1, "0b00") and matches(op2, "0b00xx") and matches(op3, "0bxxx0xxxx1")) { // SIMD scalar copy
            return error.Unimplemented;
        } else if (matches(op0, "0b01x1") and matches(op1, "0b0x") and matches(op2, "0b10xx") and matches(op3, "0bxxx00xxx1")) { // SIMD three same fp16
            return error.Unimplemented;
        } else if (matches(op0, "0b01x1") and matches(op1, "0b0x") and matches(op2, "0b1111") and matches(op3, "0b00xxxxx10")) { // SIMD scalar two reg misc fp16
            return error.Unimplemented;
        } else if (matches(op0, "0b01x1") and matches(op1, "0b0x") and matches(op2, "0bx0xx") and matches(op3, "0bxxx1xxxx1")) { // SIMD scalar three same extra
            return error.Unimplemented;
        } else if (matches(op0, "0b01x1") and matches(op1, "0b0x") and matches(op2, "0bx100") and matches(op3, "0b00xxxxx10")) { // SIMD scalar two reg misc
            const u = @as(u1, @truncate(op >> 29));
            const size = @as(u2, @truncate(op >> 22));
            const opcode = @as(u5, @truncate(op >> 12));
            const sz = @as(u1, @truncate(size));
            return if (u == 0b0 and opcode == 0b00011)
                Instruction{ .suqadd = undefined }
            else if (u == 0b0 and opcode == 0b00111)
                Instruction{ .sqabs = undefined }
            else if (u == 0b0 and opcode == 0b01000)
                Instruction{ .cmgt = undefined }
            else if (u == 0b0 and opcode == 0b01001)
                Instruction{ .cmeq = undefined }
            else if (u == 0b0 and opcode == 0b01010)
                Instruction{ .cmlt = undefined }
            else if (u == 0b0 and opcode == 0b01011)
                Instruction{ .abs = undefined }
            else if (u == 0b0 and opcode == 0b10100)
                Instruction{ .sqxtn = undefined }
            else if (u == 0b0 and matches(size, "0b0x") and opcode == 0b11010)
                Instruction{ .fcvtns = undefined }
            else if (u == 0b0 and matches(size, "0b0x") and opcode == 0b11011)
                Instruction{ .fcvtms = undefined }
            else if (u == 0b0 and matches(size, "0b0x") and opcode == 0b11100)
                Instruction{ .fcvtas = undefined }
            else if (u == 0b0 and matches(size, "0b0x") and opcode == 0b11101)
                Instruction{ .scvtf = undefined }
            else if (u == 0b0 and matches(size, "0b1x") and opcode == 0b01100)
                Instruction{ .fcmgt = undefined }
            else if (u == 0b0 and matches(size, "0b1x") and opcode == 0b01101)
                Instruction{ .fcmeq = undefined }
            else if (u == 0b0 and matches(size, "0b1x") and opcode == 0b01110)
                Instruction{ .fcmlt = undefined }
            else if (u == 0b0 and matches(size, "0b1x") and opcode == 0b11010)
                Instruction{ .fcvtps = undefined }
            else if (u == 0b0 and matches(size, "0b1x") and opcode == 0b11011)
                Instruction{ .fcvtzs = undefined }
            else if (u == 0b0 and matches(size, "0b1x") and opcode == 0b11101)
                Instruction{ .frecpe = undefined }
            else if (u == 0b0 and matches(size, "0b1x") and opcode == 0b11111)
                Instruction{ .frecpx = undefined }
            else if (u == 0b1 and opcode == 0b00011)
                Instruction{ .usqadd = undefined }
            else if (u == 0b1 and opcode == 0b00111)
                Instruction{ .sqneg = undefined }
            else if (u == 0b1 and opcode == 0b01000)
                Instruction{ .cmge = undefined }
            else if (u == 0b1 and opcode == 0b01001)
                Instruction{ .cmle = undefined }
            else if (u == 0b1 and opcode == 0b01011)
                Instruction{ .neg = undefined }
            else if (u == 0b1 and opcode == 0b10010)
                Instruction{ .sqxtun = undefined }
            else if (u == 0b1 and opcode == 0b10100)
                Instruction{ .uqxtun = undefined }
            else if (u == 0b1 and matches(size, "0b0x") and opcode == 0b10110)
                Instruction{ .fcvtxn = undefined }
            else if (u == 0b1 and matches(size, "0b0x") and opcode == 0b11010)
                Instruction{ .fcvtnu = undefined }
            else if (u == 0b1 and matches(size, "0b0x") and opcode == 0b11011)
                Instruction{ .fcvtmu = undefined }
            else if (u == 0b1 and matches(size, "0b0x") and opcode == 0b11100)
                Instruction{ .fcvtau = undefined }
            else if (u == 0b1 and matches(size, "0b0x") and opcode == 0b11101)
                Instruction{ .ucvtf = undefined }
            else if (u == 0b1 and matches(size, "0b1x") and opcode == 0b01100)
                Instruction{ .fcmge = undefined }
            else if (u == 0b1 and matches(size, "0b1x") and opcode == 0b01101)
                Instruction{ .fcmle = undefined }
            else if (u == 0b1 and matches(size, "0b1x") and opcode == 0b11010)
                Instruction{ .fcvtpu = undefined }
            else if (u == 0b1 and matches(size, "0b1x") and opcode == 0b11011)
                Instruction{ .fcvtzu = undefined }
            else if (u == 0b1 and matches(size, "0b1x") and opcode == 0b11101) blk: {
                const v = if (sz == 0b0)
                    Width.s
                else
                    Width.d;
                break :blk Instruction{ .frsqrte = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                } };
            } else error.Unallocated;
        } else if (matches(op0, "0b01x1") and matches(op1, "0b0x") and matches(op2, "0bx110") and matches(op3, "0b00xxxxx10")) { // SIMD scalar pairwise
            const u = @as(u1, @truncate(op >> 29));
            const size = @as(u2, @truncate(op >> 22));
            const opcode = @as(u5, @truncate(op >> 12));
            const sz = @as(u1, @truncate(size));
            return if (u == 0 and opcode == 0b11011)
                Instruction{ .addp = SIMDDataProcInstr{
                    .arrangement_a = if (size == 0b11)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, Width.v, false),
                    .rd = Register.from(op, Width.d, false),
                } }
            else if (u == 0 and size <= 0b01 and opcode == 0b01100)
                Instruction{ .fmaxnmp = undefined }
            else if (u == 0 and size <= 0b01 and opcode == 0b01101)
                Instruction{ .faddp = undefined }
            else if (u == 0 and size <= 0b01 and opcode == 0b01111)
                Instruction{ .fmaxp = undefined }
            else if (u == 0 and size >= 0b10 and opcode == 0b01100)
                Instruction{ .fminnmp = undefined }
            else if (u == 0 and size >= 0b10 and opcode == 0b01111)
                Instruction{ .fminp = undefined }
            else if (u == 1 and size <= 0b01 and opcode == 0b01100)
                Instruction{ .fmaxnmp = undefined }
            else if (u == 1 and size <= 0b01 and opcode == 0b01101) blk: {
                const v = if (sz == 0b0)
                    Width.s
                else
                    Width.d;
                const t = if (sz == 0b0)
                    SIMDArrangement.@"2s"
                else
                    SIMDArrangement.@"2d";
                break :blk Instruction{ .faddp = SIMDDataProcInstr{
                    .arrangement_a = t,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, v, false),
                } };
            } else if (u == 1 and size <= 0b01 and opcode == 0b01111)
                Instruction{ .fmaxp = undefined }
            else if (u == 1 and size >= 0b10 and opcode == 0b01100)
                Instruction{ .fminnmp = undefined }
            else if (u == 1 and size >= 0b10 and opcode == 0b01111)
                Instruction{ .fminp = undefined }
            else
                error.Unallocated;
        } else if (matches(op0, "0b01x1") and matches(op1, "0b0x") and matches(op2, "0bx1xx") and matches(op3, "0bxxxxxxx00")) { // SIMD scalar three different
            const u = @as(u1, @truncate(op >> 29));
            const size = @as(u2, @truncate(op >> 22));
            const opcode = @as(u4, @truncate(op >> 12));
            const va = if (size == 0b01)
                Width.s
            else if (size == 0b10)
                Width.d
            else
                return error.Unallocated;
            const vb = if (size == 0b01)
                Width.h
            else if (size == 0b10)
                Width.s
            else
                return error.Unallocated;
            const payload = SIMDDataProcInstr{
                .rm = Register.from(op >> 16, vb, false),
                .rn = Register.from(op >> 5, vb, false),
                .rd = Register.from(op, va, false),
            };
            return if (u == 0 and opcode == 0b1001)
                Instruction{ .sqdmlal = payload }
            else if (u == 0 and opcode == 0b1011)
                Instruction{ .sqdmlsl = payload }
            else if (u == 0 and opcode == 0b1101)
                Instruction{ .sqdmull = payload }
            else
                error.Unallocated;
        } else if (matches(op0, "0b01x1") and matches(op1, "0b0x") and matches(op2, "0bx1xx") and matches(op3, "0bxxxxxxxx1")) { // SIMD scalar three same
            const u = @as(u1, @truncate(op >> 29));
            const size = @as(u2, @truncate(op >> 22));
            const opcode = @as(u5, @truncate(op >> 11));
            const sz = @as(u1, @truncate(size));
            return if (u == 0 and opcode == 0b00001)
                Instruction{ .sqadd = undefined }
            else if (u == 0 and opcode == 0b00101)
                Instruction{ .sqsub = undefined }
            else if (u == 0 and opcode == 0b00110)
                Instruction{ .cmgt = undefined }
            else if (u == 0 and opcode == 0b00111)
                Instruction{ .cmge = undefined }
            else if (u == 0 and opcode == 0b01000)
                Instruction{ .sshl = undefined }
            else if (u == 0 and opcode == 0b01001)
                Instruction{ .sqshl = undefined }
            else if (u == 0 and opcode == 0b01010)
                Instruction{ .srshl = undefined }
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
                Instruction{ .cmtst = undefined }
            else if (u == 0 and opcode == 0b10101)
                Instruction{ .sqdmulh = undefined }
            else if (u == 0 and size <= 0b01 and opcode == 0b11011) blk: {
                const v = if (sz == 0b0)
                    Width.s
                else
                    Width.d;
                break :blk Instruction{ .fmulx = SIMDDataProcInstr{
                    .rm = Register.from(op >> 16, v, false),
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                } };
            } else if (u == 0 and size <= 0b01 and opcode == 0b11100)
                Instruction{ .fcmeq = undefined }
            else if (u == 0 and size <= 0b01 and opcode == 0b11111)
                Instruction{ .frecps = undefined }
            else if (u == 0 and size >= 0b10 and opcode == 0b11111)
                Instruction{ .frsqrts = undefined }
            else if (u == 1 and opcode == 0b00001)
                Instruction{ .uqadd = undefined }
            else if (u == 1 and opcode == 0b00101)
                Instruction{ .uqsub = undefined }
            else if (u == 1 and opcode == 0b00110)
                Instruction{ .cmhi = undefined }
            else if (u == 1 and opcode == 0b00111)
                Instruction{ .cmhs = undefined }
            else if (u == 1 and opcode == 0b01000)
                Instruction{ .ushl = undefined }
            else if (u == 1 and opcode == 0b01001)
                Instruction{ .uqshl = undefined }
            else if (u == 1 and opcode == 0b01011)
                Instruction{ .uqrshl = undefined }
            else if (u == 1 and opcode == 0b10000)
                Instruction{ .sub = undefined }
            else if (u == 1 and opcode == 0b10001)
                Instruction{ .cmeq = undefined }
            else if (u == 1 and opcode == 0b10110)
                Instruction{ .sqrdmulh = undefined }
            else if (u == 1 and opcode == 0b11100)
                Instruction{ .fcmge = undefined }
            else if (u == 1 and opcode == 0b11101)
                Instruction{ .facge = undefined }
            else if (u == 1 and opcode == 0b11010)
                Instruction{ .fabd = undefined }
            else if (u == 1 and opcode == 0b11100)
                Instruction{ .fcmgt = undefined }
            else if (u == 1 and opcode == 0b11101)
                Instruction{ .facgt = undefined }
            else
                error.Unallocated;
        } else if (matches(op0, "0b01x1") and matches(op1, "0b10") and matches(op3, "0bxxxxxxxx1")) { // SIMD scalar shift by immediate
            const u = @as(u1, @truncate(op >> 29));
            const immh = @as(u4, @truncate(op >> 19));
            const immb = @as(u3, @truncate(op >> 16));
            const immhimmb = @as(u8, immh) << 3 | immb;
            const opcode = @as(u5, @truncate(op >> 11));
            return if (u == 0 and !matches(immh, "0b0000") and matches(opcode, "0b00000")) blk: {
                const v = if (matches(immh, "0b1xxx"))
                    Width.d
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b1xxx"))
                    128 - immhimmb
                else
                    return error.Unallocated;
                break :blk Instruction{ .sshr = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 0 and !matches(immh, "0b0000") and matches(opcode, "0b00010")) blk: {
                const v = if (matches(immh, "0b1xxx"))
                    Width.d
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b1xxx"))
                    128 - immhimmb
                else
                    return error.Unallocated;
                break :blk Instruction{ .ssra = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 0 and !matches(immh, "0b0000") and matches(opcode, "0b00100")) blk: {
                const v = if (matches(immh, "0b1xxx"))
                    Width.d
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b1xxx"))
                    128 - immhimmb
                else
                    return error.Unallocated;
                break :blk Instruction{ .srshr = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 0 and !matches(immh, "0b0000") and matches(opcode, "0b00110")) blk: {
                const v = if (matches(immh, "0b1xxx"))
                    Width.d
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b1xxx"))
                    128 - immhimmb
                else
                    return error.Unallocated;
                break :blk Instruction{ .srsra = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 0 and !matches(immh, "0b0000") and matches(opcode, "0b01010")) blk: {
                const v = if (matches(immh, "0b1xxx"))
                    Width.d
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b1xxx"))
                    (@as(u7, immh) << 3 | immb) - 64
                else
                    return error.Unallocated;
                break :blk Instruction{ .shl = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 0 and !matches(immh, "0b0000") and matches(opcode, "0b01110")) blk: {
                const v = if (matches(immh, "0b0001"))
                    Width.b
                else if (matches(immh, "0b001x"))
                    Width.h
                else if (matches(immh, "0b01xx"))
                    Width.s
                else if (matches(immh, "0b1xxx"))
                    Width.d
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    immhimmb - 8
                else if (matches(immh, "0b001x"))
                    immhimmb - 16
                else if (matches(immh, "0b01xx"))
                    immhimmb - 32
                else if (matches(immh, "0b1xxx"))
                    immhimmb - 64
                else
                    return error.Unallocated;
                break :blk Instruction{ .sqshl = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 0 and !matches(immh, "0b0000") and matches(opcode, "0b10010")) blk: {
                const va = if (matches(immh, "0b0001"))
                    Width.h
                else if (matches(immh, "0b001x"))
                    Width.s
                else if (matches(immh, "0b01xx"))
                    Width.d
                else
                    return error.Unallocated;
                const vb = if (matches(immh, "0b0001"))
                    Width.b
                else if (matches(immh, "0b001x"))
                    Width.h
                else if (matches(immh, "0b01xx"))
                    Width.s
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    16 - immhimmb
                else if (matches(immh, "0b001x"))
                    32 - immhimmb
                else if (matches(immh, "0b01xx"))
                    64 - immhimmb
                else
                    return error.Unallocated;
                break :blk Instruction{ .sqshrn = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, va, false),
                    .rd = Register.from(op, vb, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 0 and !matches(immh, "0b0000") and matches(opcode, "0b10011")) blk: {
                const va = if (matches(immh, "0b0001"))
                    Width.h
                else if (matches(immh, "0b001x"))
                    Width.s
                else if (matches(immh, "0b01xx"))
                    Width.d
                else
                    return error.Unallocated;
                const vb = if (matches(immh, "0b0001"))
                    Width.b
                else if (matches(immh, "0b001x"))
                    Width.h
                else if (matches(immh, "0b01xx"))
                    Width.s
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    16 - immhimmb
                else if (matches(immh, "0b001x"))
                    32 - immhimmb
                else if (matches(immh, "0b01xx"))
                    64 - immhimmb
                else
                    return error.Unallocated;
                break :blk Instruction{ .sqrshrn = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, va, false),
                    .rd = Register.from(op, vb, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 0 and !matches(immh, "0b0000") and matches(opcode, "0b11100"))
                Instruction{ .vector_scvtf = undefined }
            else if (u == 0 and !matches(immh, "0b0000") and matches(opcode, "0b11111"))
                Instruction{ .vector_fcvtzs = undefined }
            else if (u == 1 and !matches(immh, "0b0000") and matches(opcode, "0b00000")) blk: {
                const v = if (matches(immh, "0b1xxx"))
                    Width.d
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b1xxx"))
                    128 - immhimmb
                else
                    return error.Unallocated;
                break :blk Instruction{ .ushr = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 1 and !matches(immh, "0b0000") and matches(opcode, "0b00010")) blk: {
                const v = if (matches(immh, "0b1xxx"))
                    Width.d
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b1xxx"))
                    128 - immhimmb
                else
                    return error.Unallocated;
                break :blk Instruction{ .usra = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 1 and !matches(immh, "0b0000") and matches(opcode, "0b00100")) blk: {
                const v = if (matches(immh, "0b1xxx"))
                    Width.d
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b1xxx"))
                    128 - immhimmb
                else
                    return error.Unallocated;
                break :blk Instruction{ .urshr = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 1 and !matches(immh, "0b0000") and matches(opcode, "0b00110")) blk: {
                const v = if (matches(immh, "0b1xxx"))
                    Width.d
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b1xxx"))
                    128 - immhimmb
                else
                    return error.Unallocated;
                break :blk Instruction{ .ursra = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 1 and !matches(immh, "0b0000") and matches(opcode, "0b01000")) blk: {
                const v = if (matches(immh, "0b1xxx"))
                    Width.d
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b1xxx"))
                    128 - immhimmb
                else
                    return error.Unallocated;
                break :blk Instruction{ .sri = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 1 and !matches(immh, "0b0000") and matches(opcode, "0b01010")) blk: {
                const v = if (matches(immh, "0b1xxx"))
                    Width.d
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b1xxx"))
                    immhimmb - 64
                else
                    return error.Unallocated;
                break :blk Instruction{ .sli = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 1 and !matches(immh, "0b0000") and matches(opcode, "0b01100")) blk: {
                const v = if (matches(immh, "0b0001"))
                    Width.b
                else if (matches(immh, "0b001x"))
                    Width.h
                else if (matches(immh, "0b01xx"))
                    Width.s
                else if (matches(immh, "0b1xxx"))
                    Width.d
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    immhimmb - 8
                else if (matches(immh, "0b001x"))
                    immhimmb - 16
                else if (matches(immh, "0b01xx"))
                    immhimmb - 32
                else if (matches(immh, "0b1xxx"))
                    immhimmb - 64
                else
                    return error.Unallocated;
                break :blk Instruction{ .sqshlu = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 1 and !matches(immh, "0b0000") and matches(opcode, "0b01110")) blk: {
                const v = if (matches(immh, "0b0001"))
                    Width.b
                else if (matches(immh, "0b001x"))
                    Width.h
                else if (matches(immh, "0b01xx"))
                    Width.s
                else if (matches(immh, "0b1xxx"))
                    Width.d
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    immhimmb - 8
                else if (matches(immh, "0b001x"))
                    immhimmb - 16
                else if (matches(immh, "0b01xx"))
                    immhimmb - 32
                else if (matches(immh, "0b1xxx"))
                    immhimmb - 64
                else
                    return error.Unallocated;
                break :blk Instruction{ .uqshl = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 1 and !matches(immh, "0b0000") and matches(opcode, "0b10000")) blk: {
                const va = if (matches(immh, "0b0001"))
                    Width.h
                else if (matches(immh, "0b001x"))
                    Width.s
                else if (matches(immh, "0b01xx"))
                    Width.d
                else
                    return error.Unallocated;
                const vb = if (matches(immh, "0b0001"))
                    Width.b
                else if (matches(immh, "0b001x"))
                    Width.h
                else if (matches(immh, "0b01xx"))
                    Width.s
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    16 - immhimmb
                else if (matches(immh, "0b001x"))
                    32 - immhimmb
                else if (matches(immh, "0b01xx"))
                    64 - immhimmb
                else
                    return error.Unallocated;
                break :blk Instruction{ .sqshrun = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, va, false),
                    .rd = Register.from(op, vb, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 1 and !matches(immh, "0b0000") and matches(opcode, "0b10001")) blk: {
                const va = if (matches(immh, "0b0001"))
                    Width.h
                else if (matches(immh, "0b001x"))
                    Width.s
                else if (matches(immh, "0b01xx"))
                    Width.d
                else
                    return error.Unallocated;
                const vb = if (matches(immh, "0b0001"))
                    Width.b
                else if (matches(immh, "0b001x"))
                    Width.h
                else if (matches(immh, "0b01xx"))
                    Width.s
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    16 - immhimmb
                else if (matches(immh, "0b001x"))
                    32 - immhimmb
                else if (matches(immh, "0b01xx"))
                    64 - immhimmb
                else
                    return error.Unallocated;
                break :blk Instruction{ .sqrshrun = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, va, false),
                    .rd = Register.from(op, vb, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 1 and !matches(immh, "0b0000") and matches(opcode, "0b10010")) blk: {
                const va = if (matches(immh, "0b0001"))
                    Width.h
                else if (matches(immh, "0b001x"))
                    Width.s
                else if (matches(immh, "0b01xx"))
                    Width.d
                else
                    return error.Unallocated;
                const vb = if (matches(immh, "0b0001"))
                    Width.b
                else if (matches(immh, "0b001x"))
                    Width.h
                else if (matches(immh, "0b01xx"))
                    Width.s
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    16 - immhimmb
                else if (matches(immh, "0b001x"))
                    32 - immhimmb
                else if (matches(immh, "0b01xx"))
                    64 - immhimmb
                else
                    return error.Unallocated;
                break :blk Instruction{ .uqshrn = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, va, false),
                    .rd = Register.from(op, vb, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 1 and !matches(immh, "0b0000") and matches(opcode, "0b10010"))
                Instruction{ .uqshrn = undefined }
            else if (u == 1 and !matches(immh, "0b0000") and matches(opcode, "0b10011")) blk: {
                const va = if (matches(immh, "0b0001"))
                    Width.h
                else if (matches(immh, "0b001x"))
                    Width.s
                else if (matches(immh, "0b01xx"))
                    Width.d
                else
                    return error.Unallocated;
                const vb = if (matches(immh, "0b0001"))
                    Width.b
                else if (matches(immh, "0b001x"))
                    Width.h
                else if (matches(immh, "0b01xx"))
                    Width.s
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    16 - immhimmb
                else if (matches(immh, "0b001x"))
                    32 - immhimmb
                else if (matches(immh, "0b01xx"))
                    64 - immhimmb
                else
                    return error.Unallocated;
                break :blk Instruction{ .uqrshrn = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, va, false),
                    .rd = Register.from(op, vb, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 1 and !matches(immh, "0b0000") and matches(opcode, "0b11100")) blk: {
                const v = if (matches(immh, "0b001x"))
                    Width.h
                else if (matches(immh, "0b01xx"))
                    Width.s
                else if (matches(immh, "0b1xxx"))
                    Width.d
                else
                    return error.Unallocated;
                const fbits = if (matches(immh, "0b001x"))
                    32 - immhimmb
                else if (matches(immh, "0b01xx"))
                    64 - immhimmb
                else if (matches(immh, "0b1xxx"))
                    128 - immhimmb
                else
                    return error.Unallocated;
                break :blk Instruction{ .vector_ucvtf = SIMDDataProcInstr{
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                    .payload = .{ .imm = fbits },
                } };
            } else if (u == 1 and !matches(immh, "0b0000") and matches(opcode, "0b11111"))
                Instruction{ .vector_fcvtzu = undefined }
            else
                error.Unallocated;
        } else if (matches(op0, "0b01x1") and matches(op1, "0b1x") and matches(op3, "0bxxxxxxxx0")) { // SIMD scalar x indexed element
            const u = @as(u1, @truncate(op >> 29));
            const size = @as(u2, @truncate(op >> 22));
            const l = @as(u1, @truncate(op >> 21));
            const m = @as(u1, @truncate(op >> 20));
            const h = @as(u1, @truncate(op >> 11));
            const sz = @as(u1, @truncate(size));
            const v = if (sz == 0b0) Width.s else Width.d;
            const opcode = @as(u4, @truncate(op >> 12));
            return if (u == 0b0 and opcode == 0b0011) blk: {
                const va = if (size == 0b01)
                    Width.s
                else if (size == 0b10)
                    Width.d
                else
                    return error.Unallocated;
                const vb = if (size == 0b01)
                    Width.h
                else if (size == 0b10)
                    Width.s
                else
                    return error.Unallocated;
                const vm = if (size == 0b01)
                    @as(u4, @truncate(op >> 16))
                else if (size == 0b10)
                    @as(u5, m) << 4 | @as(u4, @truncate(op >> 16))
                else
                    return error.Unallocated;
                break :blk Instruction{ .sqdmlal = SIMDDataProcInstr{
                    .arrangement_a = if (size == 0b01)
                        .h
                    else if (size == 0b10)
                        .s
                    else
                        return error.Unallocated,
                    .rm = Register.from(vm, .v, false),
                    .rn = Register.from(op >> 5, vb, false),
                    .rd = Register.from(op, va, false),
                    .post_index = if (size == 0b01)
                        @as(u3, h) << 2 | @as(u2, l) << 1 | m
                    else if (size == 0b10)
                        @as(u2, h) << 1 | l
                    else
                        return error.Unallocated,
                } };
            } else if (u == 0b0 and opcode == 0b0111) blk: {
                const va = if (size == 0b01)
                    Width.s
                else if (size == 0b10)
                    Width.d
                else
                    return error.Unallocated;
                const vb = if (size == 0b01)
                    Width.h
                else if (size == 0b10)
                    Width.s
                else
                    return error.Unallocated;
                const vm = if (size == 0b01)
                    @as(u4, @truncate(op >> 16))
                else if (size == 0b10)
                    @as(u5, m) << 4 | @as(u4, @truncate(op >> 16))
                else
                    return error.Unallocated;
                break :blk Instruction{ .sqdmlsl = SIMDDataProcInstr{
                    .arrangement_a = if (size == 0b01)
                        .h
                    else if (size == 0b10)
                        .s
                    else
                        return error.Unallocated,
                    .rm = Register.from(vm, .v, false),
                    .rn = Register.from(op >> 5, vb, false),
                    .rd = Register.from(op, va, false),
                    .post_index = if (size == 0b01)
                        @as(u3, h) << 2 | @as(u2, l) << 1 | m
                    else if (size == 0b10)
                        @as(u2, h) << 1 | l
                    else
                        return error.Unallocated,
                } };
            } else if (u == 0b0 and opcode == 0b1011) blk: {
                const va = if (size == 0b01)
                    Width.s
                else if (size == 0b10)
                    Width.d
                else
                    return error.Unallocated;
                const vb = if (size == 0b01)
                    Width.h
                else if (size == 0b10)
                    Width.s
                else
                    return error.Unallocated;
                const vm = if (size == 0b01)
                    @as(u4, @truncate(op >> 16))
                else if (size == 0b10)
                    @as(u5, m) << 4 | @as(u4, @truncate(op >> 16))
                else
                    return error.Unallocated;
                break :blk Instruction{ .sqdmull = SIMDDataProcInstr{
                    .arrangement_a = if (size == 0b01)
                        .h
                    else if (size == 0b10)
                        .s
                    else
                        return error.Unallocated,
                    .rm = Register.from(vm, .v, false),
                    .rn = Register.from(op >> 5, vb, false),
                    .rd = Register.from(op, va, false),
                    .post_index = if (size == 0b01)
                        @as(u3, h) << 2 | @as(u2, l) << 1 | m
                    else if (size == 0b10)
                        @as(u2, h) << 1 | l
                    else
                        return error.Unallocated,
                } };
            } else if (u == 0b0 and opcode == 0b1100) blk: {
                const va = if (size == 0b01) Width.h else if (size == 0b10)
                    Width.s
                else
                    return error.Unallocated;
                const vm = if (size == 0b01)
                    @as(u4, @truncate(op >> 16))
                else if (size == 0b10)
                    @as(u5, m) << 4 | @as(u4, @truncate(op >> 16))
                else
                    return error.Unallocated;
                break :blk Instruction{ .sqdmulh = SIMDDataProcInstr{
                    .arrangement_a = if (size == 0b01)
                        .h
                    else if (size == 0b10)
                        .s
                    else
                        return error.Unallocated,
                    .rm = Register.from(vm, .v, false),
                    .rn = Register.from(op >> 5, va, false),
                    .rd = Register.from(op, va, false),
                    .post_index = if (size == 0b01)
                        @as(u3, h) << 2 | @as(u2, l) << 1 | m
                    else if (size == 0b10)
                        @as(u2, h) << 1 | l
                    else
                        return error.Unallocated,
                } };
            } else if (u == 0b0 and opcode == 0b1101) blk: {
                const va = if (size == 0b01) Width.h else if (size == 0b10)
                    Width.s
                else
                    return error.Unallocated;
                const vm = if (size == 0b01)
                    @as(u4, @truncate(op >> 16))
                else if (size == 0b10)
                    @as(u5, m) << 4 | @as(u4, @truncate(op >> 16))
                else
                    return error.Unallocated;
                break :blk Instruction{ .sqrdmulh = SIMDDataProcInstr{
                    .arrangement_a = if (size == 0b01)
                        .h
                    else if (size == 0b10)
                        .s
                    else
                        return error.Unallocated,
                    .rm = Register.from(vm, .v, false),
                    .rn = Register.from(op >> 5, va, false),
                    .rd = Register.from(op, va, false),
                    .post_index = if (size == 0b01)
                        @as(u3, h) << 2 | @as(u2, l) << 1 | m
                    else if (size == 0b10)
                        @as(u2, h) << 1 | l
                    else
                        return error.Unallocated,
                } };
            } else if (u == 0b0 and size == 0b00 and opcode == 0b0001)
                Instruction{ .fmla = undefined }
            else if (u == 0b0 and size == 0b00 and opcode == 0b0101)
                Instruction{ .fmls = undefined }
            else if (u == 0b0 and size == 0b00 and opcode == 0b1001)
                Instruction{ .vector_fmul = undefined }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b0001)
                Instruction{ .fmla = SIMDDataProcInstr{
                    .arrangement_a = if (sz == 0b0) .s else .d,
                    .rm = Register.from(op >> 16, .v, false),
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                    .post_index = if (sz == 0b0)
                        @as(u2, h) << 1 | l
                    else if (l == 0)
                        h
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b0101)
                Instruction{ .fmls = SIMDDataProcInstr{
                    .arrangement_a = if (sz == 0b0) .s else .d,
                    .rm = Register.from(op >> 16, .v, false),
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                    .post_index = if (sz == 0b0)
                        @as(u2, h) << 1 | l
                    else if (l == 0)
                        h
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b1001)
                Instruction{ .vector_fmul = SIMDDataProcInstr{
                    .arrangement_a = if (sz == 0b0) .s else .d,
                    .rm = Register.from(op >> 16, .v, false),
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                    .post_index = if (sz == 0b0)
                        @as(u2, h) << 1 | l
                    else if (l == 0)
                        h
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b1 and opcode == 0b1101)
                Instruction{ .sqrdmlah = undefined }
            else if (u == 0b1 and opcode == 0b1111)
                Instruction{ .sqrdmlsh = undefined }
            else if (u == 0b1 and size == 0b00 and opcode == 0b1001)
                Instruction{ .fmulx = undefined }
            else if (u == 0b1 and size >= 0b10 and opcode == 0b1001)
                Instruction{ .fmulx = SIMDDataProcInstr{
                    .arrangement_a = if (sz == 0b0) .s else .d,
                    .rm = Register.from(op >> 16, .v, false),
                    .rn = Register.from(op >> 5, v, false),
                    .rd = Register.from(op, v, false),
                    .post_index = if (sz == 0b0)
                        @as(u2, h) << 1 | l
                    else if (l == 0)
                        h
                    else
                        return error.Unallocated,
                } }
            else
                error.Unallocated;
        } else if (matches(op0, "0b0x00") and matches(op1, "0b0x") and matches(op2, "0bx0xx") and matches(op3, "0bxxx0xxx00")) { // SIMD table lookup
            const q = @as(u1, @truncate(op >> 30));
            const o2 = @as(u2, @truncate(op >> 22));
            const len = @as(u2, @truncate(op >> 13));
            const o = @as(u1, @truncate(op >> 12));
            const t = @as(u5, @truncate(op >> 5));
            const rt = Register.from(t, .v, false);
            const rt2 = Register.from((t + 1) % 31, .v, false);
            const rt3 = Register.from((t + 2) % 31, .v, false);
            const rt4 = Register.from((t + 3) % 31, .v, false);
            if (o2 != 0b00) return error.Unallocated;
            const payload = SIMDLoadStoreInstr{
                .arrangement = if (q == 0b0)
                    SIMDArrangement.@"8b"
                else
                    SIMDArrangement.@"16b",
                .rd = Register.from(op, .v, false),
                .rt = rt,
                .rt2 = if (len >= 0b01) rt2 else null,
                .rt3 = if (len >= 0b10) rt3 else null,
                .rt4 = if (len >= 0b11) rt4 else null,
                .payload = .{ .rm = Register.from(op >> 16, .v, false) },
            };
            return if (o == 0b0)
                Instruction{ .tbl = payload }
            else
                Instruction{ .tbx = payload };
        } else if (matches(op0, "0b0x00") and matches(op1, "0b0x") and matches(op2, "0bx0xx") and matches(op3, "0bxxx0xxx10")) { // SIMD permute
            return error.Unimplemented;
        } else if (matches(op0, "0b0x10") and matches(op1, "0b0x") and matches(op2, "0bx0xx") and matches(op3, "0bxxx0xxxx0")) { // SIMD extract
            return error.Unimplemented;
        } else if (matches(op0, "0b0xx0") and matches(op1, "0b00") and matches(op2, "0b00xx") and matches(op3, "0bxxx0xxxx1")) { // SIMD copy
            const q = @as(u1, @truncate(op >> 30));
            const u = @as(u1, @truncate(op >> 29));
            const imm5 = @as(u5, @truncate(op >> 16));
            const imm4 = @as(u4, @truncate(op >> 11));
            return if (u == 0b0 and imm4 == 0b0000)
                Instruction{ .dup = SIMDDataProcInstr{
                    .arrangement_a = if (@as(u1, @truncate(imm5)) == 0b1 and q == 0b0)
                        SIMDArrangement.@"8b"
                    else if (@as(u1, @truncate(imm5)) == 0b1 and q == 0b1)
                        SIMDArrangement.@"16b"
                    else if (@as(u2, @truncate(imm5)) == 0b10 and q == 0b0)
                        SIMDArrangement.@"4h"
                    else if (@as(u2, @truncate(imm5)) == 0b10 and q == 0b1)
                        SIMDArrangement.@"8h"
                    else if (@as(u3, @truncate(imm5)) == 0b100 and q == 0b0)
                        SIMDArrangement.@"2s"
                    else if (@as(u3, @truncate(imm5)) == 0b100 and q == 0b1)
                        SIMDArrangement.@"4s"
                    else if (@as(u4, @truncate(imm5)) == 0b1000 and q == 0b1)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, Width.v, false),
                    .rd = Register.from(op, Width.v, false),
                    .post_index = if (@as(u1, @truncate(imm5)) == 0b1)
                        @as(u4, @truncate(imm5 >> 1))
                    else if (@as(u2, @truncate(imm5)) == 0b10)
                        @as(u3, @truncate(imm5 >> 2))
                    else if (@as(u3, @truncate(imm5)) == 0b100)
                        @as(u2, @truncate(imm5 >> 3))
                    else if (@as(u4, @truncate(imm5)) == 0b1000)
                        @as(u1, @truncate(imm5 >> 4))
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b0 and imm4 == 0b0001) blk: {
                const width = if (@as(u1, @truncate(imm5)) == 0b1 or
                    @as(u2, @truncate(imm5)) == 0b10 or
                    @as(u3, @truncate(imm5)) == 0b100)
                    Width.w
                else if (@as(u4, @truncate(imm5)) == 0b1000) Width.x else return error.Unallocated;
                break :blk Instruction{ .dup = SIMDDataProcInstr{
                    .arrangement_a = if (@as(u1, @truncate(imm5)) == 0b1 and q == 0b0)
                        SIMDArrangement.@"8b"
                    else if (@as(u1, @truncate(imm5)) == 0b1 and q == 0b1)
                        SIMDArrangement.@"16b"
                    else if (@as(u2, @truncate(imm5)) == 0b10 and q == 0b0)
                        SIMDArrangement.@"4h"
                    else if (@as(u2, @truncate(imm5)) == 0b10 and q == 0b1)
                        SIMDArrangement.@"8h"
                    else if (@as(u3, @truncate(imm5)) == 0b100 and q == 0b0)
                        SIMDArrangement.@"2s"
                    else if (@as(u3, @truncate(imm5)) == 0b100 and q == 0b1)
                        SIMDArrangement.@"4s"
                    else if (@as(u4, @truncate(imm5)) == 0b1000 and q == 0b1)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, width, false),
                    .rd = Register.from(op, .v, false),
                } };
            } else if (u == 0b0 and imm4 == 0b0101) blk: {
                const width = if (q == 0b0) Width.w else Width.x;
                break :blk Instruction{ .smov = SIMDDataProcInstr{
                    .arrangement_a = if (@as(u1, @truncate(imm5)) == 0b1)
                        SIMDArrangement.b
                    else if (@as(u2, @truncate(imm5)) == 0b10)
                        SIMDArrangement.h
                    else if (width == .x and @as(u3, @truncate(imm5)) == 0b100)
                        SIMDArrangement.s
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, width, false),
                    .post_index = if (@as(u1, @truncate(imm5)) == 0b1)
                        @as(u4, @truncate(imm5 >> 1))
                    else if (@as(u2, @truncate(imm5)) == 0b10)
                        @as(u3, @truncate(imm5 >> 2))
                    else if (width == .x and @as(u3, @truncate(imm5)) == 0b100)
                        @as(u2, @truncate(imm5 >> 3))
                    else
                        return error.Unallocated,
                } };
            } else if ((q == 0b0 or (q == 0b1 and @as(u4, @truncate(imm5)) == 0b1000)) and
                u == 0b0 and imm4 == 0b0111)
            blk: {
                const width = if (q == 0b0) Width.w else Width.x;
                const payload = SIMDDataProcInstr{
                    .arrangement_a = if (width == .w and @as(u1, @truncate(imm5)) == 0b1)
                        SIMDArrangement.b
                    else if (width == .w and @as(u2, @truncate(imm5)) == 0b10)
                        SIMDArrangement.h
                    else if (width == .w and @as(u3, @truncate(imm5)) == 0b100)
                        SIMDArrangement.s
                    else if (width == .x and @as(u4, @truncate(imm5)) == 0b1000)
                        SIMDArrangement.d
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, width, false),
                    .post_index = if (width == .w and @as(u1, @truncate(imm5)) == 0b1)
                        @as(u4, @truncate(imm5 >> 1))
                    else if (width == .w and @as(u2, @truncate(imm5)) == 0b10)
                        @as(u3, @truncate(imm5 >> 2))
                    else if (width == .w and @as(u3, @truncate(imm5)) == 0b100)
                        @as(u2, @truncate(imm5 >> 3))
                    else if (width == .x and @as(u4, @truncate(imm5)) == 0b1000)
                        @as(u1, @truncate(imm5 >> 4))
                    else
                        return error.Unallocated,
                };
                break :blk if ((width == .w and @as(u3, @truncate(imm5)) == 0b100) or
                    (width == .x and @as(u4, @truncate(imm5)) == 0b1000))
                    Instruction{ .vector_mov = payload }
                else
                    Instruction{ .umov = payload };
            } else if (q == 0b1 and (u == 0b1 or (u == 0b0 and imm4 == 0b0011))) blk: {
                const width = if (u == 0b1)
                    Width.v
                else if (@as(u1, @truncate(imm5)) == 0b1)
                    Width.w
                else if (@as(u2, @truncate(imm5)) == 0b10)
                    Width.w
                else if (@as(u3, @truncate(imm5)) == 0b100)
                    Width.w
                else if (@as(u4, @truncate(imm5)) == 0b1000)
                    Width.x
                else
                    return error.Unallocated;
                break :blk Instruction{ .ins = SIMDDataProcInstr{
                    .arrangement_a = if (@as(u1, @truncate(imm5)) == 0b1)
                        SIMDArrangement.b
                    else if (@as(u2, @truncate(imm5)) == 0b10)
                        SIMDArrangement.h
                    else if (@as(u3, @truncate(imm5)) == 0b100)
                        SIMDArrangement.s
                    else if (@as(u4, @truncate(imm5)) == 0b1000)
                        SIMDArrangement.d
                    else
                        undefined,
                    .index = if (@as(u1, @truncate(imm5)) == 0b1)
                        @as(u4, @truncate(imm5 >> 1))
                    else if (@as(u2, @truncate(imm5)) == 0b10)
                        @as(u3, @truncate(imm5 >> 2))
                    else if (@as(u3, @truncate(imm5)) == 0b100)
                        @as(u2, @truncate(imm5 >> 3))
                    else if (@as(u4, @truncate(imm5)) == 0b1000)
                        @as(u1, @truncate(imm5 >> 4))
                    else
                        undefined,
                    .rn = Register.from(op >> 5, width, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (u == 0b1)
                        if (@as(u1, @truncate(imm5)) == 0b1)
                            imm4
                        else if (@as(u2, @truncate(imm5)) == 0b10)
                            @as(u3, @truncate(imm4 >> 1))
                        else if (@as(u3, @truncate(imm5)) == 0b100)
                            @as(u2, @truncate(imm4 >> 2))
                        else if (@as(u4, @truncate(imm5)) == 0b1000)
                            @as(u1, @truncate(imm4 >> 3))
                        else
                            undefined
                    else
                        null,
                } };
            } else error.Unallocated;
        } else if (matches(op0, "0b0xx0") and matches(op1, "0b0x") and matches(op2, "0b10xx") and matches(op3, "0bxxx00xxx1")) { // SIMD three same (fp16)
            return error.Unimplemented;
        } else if (matches(op0, "0b0xx0") and matches(op1, "0b0x") and matches(op2, "0b1111") and matches(op3, "0b00xxxxx10")) { // SIMD two reg misc (fp16)
            return error.Unimplemented;
        } else if (matches(op0, "0b0xx0") and matches(op1, "0b0x") and matches(op2, "0bx0xx") and matches(op3, "0bxxx1xxxx1")) { // SIMD three reg extension
            return error.Unimplemented;
        } else if (matches(op0, "0b0xx0") and matches(op1, "0b0x") and matches(op2, "0bx100") and matches(op3, "0b00xxxxx10")) { // SIMD two reg misc
            const u = @as(u1, @truncate(op >> 29));
            const size = @as(u2, @truncate(op >> 22));
            const opcode = @as(u5, @truncate(op >> 12));
            const q = @as(u1, @truncate(op >> 30));
            const sizeq = @as(u3, size) << 1 | q;
            const rn = Register.from(op >> 5, .v, false);
            const rd = Register.from(op, .v, false);
            return if (u == 0b0 and opcode == 0b00000) // SIMD two reg misc
                Instruction{ .rev64 = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and opcode == 0b00001)
                Instruction{ .vector_rev16 = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"8b"
                    else
                        SIMDArrangement.@"16b",
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and opcode == 0b00010)
                Instruction{ .saddlp = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"4h"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"8h"
                    else if (sizeq == 0b010)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b100)
                        SIMDArrangement.@"1d"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and opcode == 0b00011)
                Instruction{ .suqadd = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and opcode == 0b00100)
                Instruction{ .vector_cls = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and opcode == 0b00101)
                Instruction{ .cnt = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"8b"
                    else
                        SIMDArrangement.@"16b",
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and opcode == 0b00110)
                Instruction{ .sadalp = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"4h"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"8h"
                    else if (sizeq == 0b010)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b100)
                        SIMDArrangement.@"1d"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and opcode == 0b00111)
                Instruction{ .sqabs = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and opcode == 0b01000)
                Instruction{ .cmgt = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                    .payload = .{ .shift = 0 },
                } }
            else if (u == 0b0 and opcode == 0b01001)
                Instruction{ .cmeq = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                    .payload = .{ .shift = 0 },
                } }
            else if (u == 0b0 and opcode == 0b01010)
                Instruction{ .cmlt = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                    .payload = .{ .shift = 0 },
                } }
            else if (u == 0b0 and opcode == 0b01011)
                Instruction{ .abs = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and opcode == 0b10010)
                Instruction{ .xtn = SIMDDataProcInstr{
                    .q = q == 0b1,
                    .arrangement_a = if (sizeq <= 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and opcode == 0b10100)
                Instruction{ .sqxtn = SIMDDataProcInstr{
                    .q = q == 0b1,
                    .arrangement_a = if (sizeq <= 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and size <= 0b01 and opcode == 0b10110)
                Instruction{ .fcvtn = SIMDDataProcInstr{
                    .q = q == 0b1,
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"4h"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"8h"
                    else if (sizeq == 0b010)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"4s"
                    else
                        return error.Unallocated,
                    .arrangement_b = if (size == 0b00)
                        SIMDArrangement.@"4s"
                    else
                        SIMDArrangement.@"2d",
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and size <= 0b01 and opcode == 0b10111)
                Instruction{ .fcvtl = SIMDDataProcInstr{
                    .q = q == 0b1,
                    .arrangement_a = if (size == 0b00)
                        SIMDArrangement.@"4s"
                    else
                        SIMDArrangement.@"2d",
                    .arrangement_b = if (sizeq == 0b000)
                        SIMDArrangement.@"4h"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"8h"
                    else if (sizeq == 0b010)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"4s"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and size <= 0b01 and opcode == 0b11000)
                Instruction{ .vector_frintn = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and size <= 0b01 and opcode == 0b11001)
                Instruction{ .vector_frintm = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and size <= 0b01 and opcode == 0b11010)
                Instruction{ .vector_fcvtns = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and size <= 0b01 and opcode == 0b11011)
                Instruction{ .vector_fcvtms = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and size <= 0b01 and opcode == 0b11100)
                Instruction{ .vector_fcvtas = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and size <= 0b01 and opcode == 0b11101)
                Instruction{ .vector_scvtf = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and size <= 0b01 and opcode == 0b11110)
                Instruction{ .vector_frint32z = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and size <= 0b01 and opcode == 0b11111)
                Instruction{ .vector_frint64z = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b01100)
                Instruction{ .fcmgt = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                    .payload = .{ .shift = 0 },
                } }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b01101)
                Instruction{ .fcmeq = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                    .payload = .{ .shift = 0 },
                } }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b01110)
                Instruction{ .fcmlt = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                    .payload = .{ .shift = 0 },
                } }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b01111)
                Instruction{ .vector_fabs = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b11000)
                Instruction{ .vector_frintp = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b11001)
                Instruction{ .vector_frintz = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b11010)
                Instruction{ .vector_fcvtps = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b11011)
                Instruction{ .vector_fcvtzs = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b11100)
                Instruction{ .urecpe = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"2s"
                    else
                        SIMDArrangement.@"4s",
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b11101)
                Instruction{ .frecpe = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b0 and size == 0b10 and opcode == 0b10110)
                Instruction{ .bfcvtn = SIMDDataProcInstr{
                    .q = q == 0b1,
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"4h"
                    else
                        SIMDArrangement.@"8h",
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and opcode == 0b00000)
                Instruction{ .vector_rev32 = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and opcode == 0b00010)
                Instruction{ .uaddlp = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"4h"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"8h"
                    else if (sizeq == 0b010)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b100)
                        SIMDArrangement.@"1d"
                    else if (sizeq == 0b100)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and opcode == 0b00011)
                Instruction{ .usqadd = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and opcode == 0b00100)
                Instruction{ .vector_clz = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and opcode == 0b00110)
                Instruction{ .uadalp = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"4h"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"8h"
                    else if (sizeq == 0b010)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b100)
                        SIMDArrangement.@"1d"
                    else if (sizeq == 0b100)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and opcode == 0b00111)
                Instruction{ .sqneg = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and opcode == 0b01000)
                Instruction{ .cmge = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                    .payload = .{ .shift = 0 },
                } }
            else if (u == 0b1 and opcode == 0b01001)
                Instruction{ .cmle = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                    .payload = .{ .shift = 0 },
                } }
            else if (u == 0b1 and opcode == 0b01011)
                Instruction{ .neg = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and opcode == 0b10010)
                Instruction{ .sqxtun = SIMDDataProcInstr{
                    .q = q == 0b1,
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and opcode == 0b10011)
                Instruction{ .shll = SIMDDataProcInstr{
                    .q = q == 0b1,
                    .arrangement_a = if (size == 0b00)
                        SIMDArrangement.@"8h"
                    else if (size == 0b01)
                        SIMDArrangement.@"4s"
                    else if (size == 0b10)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                    .payload = .{
                        .shift = if (size == 0b00)
                            8
                        else if (size == 0b01)
                            16
                        else if (size == 0b10)
                            32
                        else
                            return error.Unallocated,
                    },
                } }
            else if (u == 0b1 and opcode == 0b10100)
                Instruction{ .uqxtn = SIMDDataProcInstr{
                    .q = q == 0b1,
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and size <= 0b01 and opcode == 0b10110)
                Instruction{ .fcvtxn = SIMDDataProcInstr{
                    .q = q == 0b1,
                    .arrangement_a = if (sizeq == 0b010)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"4s"
                    else
                        return error.Unallocated,
                    .arrangement_b = if (size == 0b01)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and size <= 0b01 and opcode == 0b11000)
                Instruction{ .vector_frinta = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and size <= 0b01 and opcode == 0b11001)
                Instruction{ .vector_frintx = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and size <= 0b01 and opcode == 0b11010)
                Instruction{ .vector_fcvtnu = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and size <= 0b01 and opcode == 0b11011)
                Instruction{ .vector_fcvtmu = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and size <= 0b01 and opcode == 0b11100)
                Instruction{ .vector_fcvtau = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and size <= 0b01 and opcode == 0b11101)
                Instruction{ .vector_ucvtf = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and size <= 0b01 and opcode == 0b11110)
                Instruction{ .vector_frint32x = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and size <= 0b01 and opcode == 0b11111)
                Instruction{ .vector_frint64x = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and size == 0b00 and opcode == 0b00101)
                Instruction{ .not = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"8b"
                    else
                        SIMDArrangement.@"16b",
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and size == 0b01 and opcode == 0b00101)
                Instruction{ .vector_rbit = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"8b"
                    else
                        SIMDArrangement.@"16b",
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and size >= 0b10 and opcode == 0b01100)
                Instruction{ .fcmge = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                    .payload = .{ .shift = 0 },
                } }
            else if (u == 0b1 and size >= 0b10 and opcode == 0b01101)
                Instruction{ .fcmle = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                    .payload = .{ .shift = 0 },
                } }
            else if (u == 0b1 and size >= 0b10 and opcode == 0b01111)
                Instruction{ .vector_fneg = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and size >= 0b10 and opcode == 0b11001)
                Instruction{ .vector_frinti = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and size >= 0b10 and opcode == 0b11010)
                Instruction{ .vector_fcvtpu = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and size >= 0b10 and opcode == 0b11011)
                Instruction{ .vector_fcvtzu = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and size >= 0b10 and opcode == 0b11100)
                Instruction{ .ursqrte = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and size >= 0b10 and opcode == 0b11101)
                Instruction{ .frsqrte = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0b1 and size >= 0b10 and opcode == 0b11111)
                Instruction{ .vector_fsqrt = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rn = rn,
                    .rd = rd,
                } }
            else
                error.Unallocated;
        } else if (matches(op0, "0b0xx0") and matches(op1, "0b0x") and matches(op2, "0bx110") and matches(op3, "0b00xxxxx10")) { // SIMD across lanes
            const u = @as(u1, @truncate(op >> 29));
            const size = @as(u2, @truncate(op >> 22));
            const opcode = @as(u5, @truncate(op >> 12));
            const q = @as(u1, @truncate(op >> 30));
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
                    .arrangement_a = if (sizeq != 0b100)
                        @enumFromInt(sizeq)
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
        } else if (matches(op0, "0b0xx0") and matches(op1, "0b0x") and matches(op2, "0bx1xx") and matches(op3, "0bxxxxxxx00")) { // SIMD three different
            const u = @as(u1, @truncate(op >> 29));
            const opcode = @as(u4, @truncate(op >> 12));
            const size = @as(u2, @truncate(op >> 22));
            const q = @as(u1, @truncate(op >> 30));
            const sizeq = @as(u3, size) << 1 | q;
            return if (u == 0 and opcode == 0b0000)
                @as(Instruction, Instruction.saddl)
            else if (u == 0 and opcode == 0b0001)
                @as(Instruction, Instruction.saddw)
            else if (u == 0 and opcode == 0b0010)
                @as(Instruction, Instruction.ssubl)
            else if (u == 0 and opcode == 0b0011)
                @as(Instruction, Instruction.ssubw)
            else if (u == 0 and opcode == 0b0100)
                Instruction{ .addhn = SIMDDataProcInstr{
                    .q = @as(u1, @truncate(op >> 30)) == 1,
                    .arrangement_a = if (size != 0b11)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = Register.from(op >> 16, .v, false),
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                } }
            else if (u == 0 and opcode == 0b0101)
                @as(Instruction, Instruction.sabal)
            else if (u == 0 and opcode == 0b0110)
                @as(Instruction, Instruction.subhn)
            else if (u == 0 and opcode == 0b0111)
                @as(Instruction, Instruction.sabdl)
            else if (opcode == 0b1000) blk: {
                const payload = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = if (size == 0b00)
                        SIMDArrangement.@"8h"
                    else if (size == 0b01)
                        SIMDArrangement.@"4s"
                    else if (size == 0b10)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = Register.from(op >> 16, .v, false),
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                };
                break :blk if (u == 0b0)
                    Instruction{ .smlal = payload }
                else
                    Instruction{ .umlal = payload };
            } else if (u == 0 and opcode == 0b1001)
                Instruction{ .sqdmlal = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = if (size == 0b01)
                        SIMDArrangement.@"4s"
                    else if (size == 0b10)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = Register.from(op >> 16, .v, false),
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                } }
            else if (u == 0 and opcode == 0b1010)
                Instruction{ .smlsl = undefined }
            else if (u == 0 and opcode == 0b1011)
                Instruction{ .sqdmlsl = undefined }
            else if (u == 0 and opcode == 0b1100)
                Instruction{ .smull = undefined }
            else if (u == 0 and opcode == 0b1101)
                Instruction{ .sqdmull = undefined }
            else if (u == 0 and opcode == 0b1110)
                Instruction{ .pmull = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = if (size == 0b00)
                        SIMDArrangement.@"8h"
                    else if (size == 0b11)
                        SIMDArrangement.@"1q"
                    else
                        return error.Unallocated,
                    .rm = Register.from(op >> 16, .v, false),
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                } }
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
            else if (u == 1 and opcode == 0b1010)
                Instruction{ .umlsl = undefined }
            else if (u == 1 and opcode == 0b1100)
                Instruction{ .umull = undefined }
            else
                error.Unallocated;
        } else if (matches(op0, "0b0xx0") and matches(op1, "0b0x") and matches(op2, "0bx1xx") and matches(op3, "0bxxxxxxxx1")) { // SIMD three same
            const u = @as(u1, @truncate(op >> 29));
            const size = @as(u2, @truncate(op >> 22));
            const opcode = @as(u5, @truncate(op >> 11));
            const q = @as(u1, @truncate(op >> 30));
            const sizeq = @as(u3, size) << 1 | q;
            const rm = Register.from(op >> 16, .v, false);
            const rn = Register.from(op >> 5, .v, false);
            const rd = Register.from(op, .v, false);
            return if (u == 0 and opcode == 0b00000)
                Instruction{ .shadd = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b00001)
                Instruction{ .sqadd = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b00010)
                Instruction{ .srhadd = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b00100)
                Instruction{ .shsub = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b00101)
                Instruction{ .sqsub = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b00110)
                Instruction{ .cmgt = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b00111)
                Instruction{ .cmge = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b01000)
                Instruction{ .sshl = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b01001)
                Instruction{ .sqshl = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b01010)
                Instruction{ .srshl = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b01011)
                Instruction{ .sqrshl = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b01100)
                Instruction{ .smax = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b01101)
                Instruction{ .smin = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b01110)
                Instruction{ .sabd = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b01111)
                Instruction{ .saba = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b10000)
                Instruction{ .vector_add = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b10001)
                Instruction{ .cmtst = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b10010)
                Instruction{ .mla = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b10011)
                Instruction{ .mul = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b10100)
                Instruction{ .smaxp = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b10101)
                Instruction{ .sminp = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b10110)
                Instruction{ .sqdmulh = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq > 0b001 and sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and opcode == 0b10111)
                Instruction{ .addp = SIMDDataProcInstr{
                    .q = @as(u1, @truncate(op >> 30)) == 1,
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and size <= 0b01 and opcode == 0b11000)
                Instruction{ .vector_fmaxnm = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and size <= 0b01 and opcode == 0b11001)
                Instruction{ .fmla = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and size <= 0b01 and opcode == 0b11010)
                Instruction{ .vector_fadd = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and size <= 0b01 and opcode == 0b11011)
                Instruction{ .fmulx = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and size <= 0b01 and opcode == 0b11100)
                Instruction{ .fcmeq = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and size <= 0b01 and opcode == 0b11110)
                Instruction{ .vector_fmax = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and size <= 0b01 and opcode == 0b11111)
                Instruction{ .frecps = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and size == 0b00 and opcode == 0b00011)
                Instruction{ .vector_and = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"8b"
                    else
                        SIMDArrangement.@"16b",
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and size == 0b00 and opcode == 0b11101)
                @as(Instruction, Instruction.fmlal)
            else if (u == 0 and size == 0b01 and opcode == 0b00011)
                Instruction{ .vector_bic = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"8b"
                    else
                        SIMDArrangement.@"16b",
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and size >= 0b10 and opcode == 0b11000)
                Instruction{ .vector_fminnm = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and size >= 0b10 and opcode == 0b11001)
                Instruction{ .fmls = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and size >= 0b10 and opcode == 0b11010)
                Instruction{ .vector_fsub = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and size >= 0b10 and opcode == 0b11110)
                Instruction{ .vector_fmin = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and size >= 0b10 and opcode == 0b11111)
                Instruction{ .frsqrts = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 0 and size == 0b10 and opcode == 0b00011) blk: {
                const payload = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"8b"
                    else
                        SIMDArrangement.@"16b",
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                };
                break :blk if (rm.eq(&rn))
                    Instruction{ .vector_mov = payload }
                else
                    Instruction{ .vector_orr = payload };
            } else if (u == 0 and size == 0b10 and opcode == 0b11101)
                @as(Instruction, Instruction.fmlsl)
            else if (u == 0 and size == 0b11 and opcode == 0b00011)
                Instruction{ .vector_orn = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"8b"
                    else
                        SIMDArrangement.@"16b",
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b00000)
                Instruction{ .uhadd = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b00001)
                Instruction{ .uqadd = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b00010)
                Instruction{ .urhadd = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b00100)
                Instruction{ .uhsub = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b00101)
                Instruction{ .uqsub = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b00110)
                Instruction{ .cmhi = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b00111)
                Instruction{ .cmhs = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b01000)
                Instruction{ .ushl = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b01001)
                Instruction{ .uqshl = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b01010)
                Instruction{ .urshl = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b01011)
                Instruction{ .uqrshl = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b01100)
                Instruction{ .umax = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b01101)
                Instruction{ .umin = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b01110)
                Instruction{ .uabd = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b01111)
                Instruction{ .uaba = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b10000)
                Instruction{ .vector_sub = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b10001)
                Instruction{ .cmeq = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b10010)
                Instruction{ .mls = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b10011)
                Instruction{ .pmul = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"8b"
                    else
                        SIMDArrangement.@"16b",
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b10100)
                Instruction{ .umaxp = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b10101)
                Instruction{ .uminp = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and opcode == 0b10110)
                Instruction{ .sqrdmulh = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq > 0b001 and sizeq < 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and size <= 0b01 and opcode == 0b11000)
                Instruction{ .fmaxnmp = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and size <= 0b01 and opcode == 0b11010)
                Instruction{ .faddp = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and size <= 0b01 and opcode == 0b11011)
                Instruction{ .vector_fmul = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and size <= 0b01 and opcode == 0b11100)
                Instruction{ .fcmge = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and size <= 0b01 and opcode == 0b11101)
                Instruction{ .facge = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and size <= 0b01 and opcode == 0b11110)
                Instruction{ .fmaxp = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and size <= 0b01 and opcode == 0b11111)
                Instruction{ .vector_fdiv = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b000)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b001)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and size == 0b00 and opcode == 0b00011)
                Instruction{ .vector_eor = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"8b"
                    else
                        SIMDArrangement.@"16b",
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and size == 0b00 and opcode == 0b11001)
                @as(Instruction, Instruction.fmlal)
            else if (u == 1 and size == 0b01 and opcode == 0b00011)
                Instruction{ .bsl = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"8b"
                    else
                        SIMDArrangement.@"16b",
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and size >= 0b10 and opcode == 0b11000)
                Instruction{ .fminnmp = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and size >= 0b10 and opcode == 0b11010)
                Instruction{ .fabd = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq != 0b110)
                        @enumFromInt(sizeq)
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and size >= 0b10 and opcode == 0b11100)
                Instruction{ .fcmgt = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and size >= 0b10 and opcode == 0b11101)
                Instruction{ .facgt = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and size >= 0b10 and opcode == 0b11110)
                Instruction{ .fminp = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else if (sizeq == 0b111)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and size == 0b10 and opcode == 0b00011)
                Instruction{ .bit = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"8b"
                    else
                        SIMDArrangement.@"16b",
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else if (u == 1 and size == 0b10 and opcode == 0b11001)
                @as(Instruction, Instruction.fmlsl)
            else if (u == 1 and size == 0b11 and opcode == 0b00011)
                Instruction{ .bif = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"8b"
                    else
                        SIMDArrangement.@"16b",
                    .rm = rm,
                    .rn = rn,
                    .rd = rd,
                } }
            else
                error.Unallocated;
        } else if (matches(op0, "0b0xx0") and matches(op1, "0b10") and matches(op2, "0b0000") and matches(op3, "0bxxxxxxxx1")) { // SIMD modified immediate
            const q = @as(u1, @truncate(op >> 30));
            const o1 = @as(u1, @truncate(op >> 29));
            const cmode = @as(u4, @truncate(op >> 12));
            const o2 = @as(u1, @truncate(op >> 11));
            const rd = Register.from(op, .v, false);
            const a = @as(u1, @truncate(op >> 18));
            const b = @as(u1, @truncate(op >> 17));
            const c = @as(u1, @truncate(op >> 16));
            const d = @as(u1, @truncate(op >> 9));
            const e = @as(u1, @truncate(op >> 8));
            const f = @as(u1, @truncate(op >> 7));
            const g = @as(u1, @truncate(op >> 6));
            const h = @as(u1, @truncate(op >> 5));
            const imm8 = @as(u8, a) << 7 | @as(u8, b) << 6 |
                @as(u8, c) << 5 | @as(u8, d) << 4 |
                @as(u8, e) << 3 | @as(u8, f) << 2 |
                @as(u8, g) << 1 | @as(u8, h);
            const imm = @as(u64, a) * 0xF0000000 | @as(u64, b) * 0x0F000000 |
                @as(u64, c) * 0x00F00000 | @as(u64, d) * 0x000F0000 |
                @as(u64, e) * 0x0000F000 | @as(u64, f) * 0x00000F00 |
                @as(u64, g) * 0x000000F0 | @as(u64, h) * 0x0000000F;
            return if (o1 == 0b0 and @as(u1, @truncate(cmode >> 3)) == 0b0 and
                @as(u1, @truncate(cmode)) == 0b0 and o2 == 0b0)
                Instruction{ .movi = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"2s"
                    else
                        SIMDArrangement.@"4s",
                    .rd = rd,
                    .payload = .{ .shifted_imm = .{
                        .shift = @as(u6, @as(u2, @truncate(cmode >> 1))) * 8,
                        .shift_ty = .lsl,
                        .imm = imm8,
                    } },
                } }
            else if (o1 == 0b0 and @as(u1, @truncate(cmode >> 3)) == 0b0 and
                @as(u1, @truncate(cmode)) == 0b1 and o2 == 0b0)
                Instruction{ .vector_orr = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"2s"
                    else
                        SIMDArrangement.@"4s",
                    .rd = rd,
                    .payload = .{ .shifted_imm = .{
                        .shift = @as(u6, @as(u2, @truncate(cmode >> 1))) * 8,
                        .shift_ty = .lsl,
                        .imm = imm8,
                    } },
                } }
            else if (o1 == 0b0 and @as(u2, @truncate(cmode >> 2)) == 0b10 and
                @as(u1, @truncate(cmode)) == 0b0 and o2 == 0b0)
                Instruction{ .movi = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"4h"
                    else
                        SIMDArrangement.@"8h",
                    .rd = rd,
                    .payload = .{ .shifted_imm = .{
                        .shift = @as(u6, @as(u1, @truncate(cmode >> 1))) * 8,
                        .shift_ty = .lsl,
                        .imm = imm8,
                    } },
                } }
            else if (o1 == 0b0 and @as(u2, @truncate(cmode >> 2)) == 0b10 and
                @as(u1, @truncate(cmode)) == 0b1 and o2 == 0b0)
                Instruction{ .vector_orr = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"4h"
                    else
                        SIMDArrangement.@"8h",
                    .rd = rd,
                    .payload = .{ .shifted_imm = .{
                        .shift = @as(u6, @as(u1, @truncate(cmode >> 1))) * 8,
                        .shift_ty = .lsl,
                        .imm = imm8,
                    } },
                } }
            else if (o1 == 0b0 and @as(u3, @truncate(cmode >> 1)) == 0b110 and o2 == 0b0)
                Instruction{ .movi = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"8b"
                    else
                        SIMDArrangement.@"16b",
                    .rd = rd,
                    .payload = .{ .shifted_imm = .{
                        .shift = (@as(u6, @as(u1, @truncate(cmode))) + 1) * 8,
                        .shift_ty = .msl,
                        .imm = imm8,
                    } },
                } }
            else if (o1 == 0b0 and cmode == 0b1110 and o2 == 0b0)
                Instruction{ .movi = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"8b"
                    else
                        SIMDArrangement.@"16b",
                    .rd = rd,
                    .payload = .{ .shifted_imm = .{
                        .shift = 0,
                        .shift_ty = .lsl,
                        .imm = imm8,
                    } },
                } }
            else if (o1 == 0b0 and cmode == 0b1111 and o2 == 0b0)
                Instruction{ .vector_fmov = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"2s"
                    else
                        SIMDArrangement.@"4s",
                    .rd = rd,
                    .payload = .{ .fp_imm = @as(f64, @floatCast(toFloatingPointConst(f32, a, b, c, d, e, f, g, h))) },
                } }
            else if (o1 == 0b0 and cmode == 0b1111 and o2 == 0b1)
                Instruction{ .vector_fmov = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"4h"
                    else
                        SIMDArrangement.@"8h",
                    .rd = rd,
                    .payload = .{ .fp_imm = @as(f64, @floatCast(toFloatingPointConst(f16, a, b, c, d, e, f, g, h))) },
                } }
            else if (o1 == 0b1 and @as(u1, @truncate(cmode >> 3)) == 0b0 and
                @as(u1, @truncate(cmode)) == 0b0 and o2 == 0b0)
                Instruction{ .mvni = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"2s"
                    else
                        SIMDArrangement.@"4s",
                    .rd = rd,
                    .payload = .{ .shifted_imm = .{
                        .shift = @as(u6, @as(u2, @truncate(cmode >> 1))) * 8,
                        .shift_ty = .lsl,
                        .imm = imm8,
                    } },
                } }
            else if (o1 == 0b1 and @as(u1, @truncate(cmode >> 3)) == 0b0 and
                @as(u1, @truncate(cmode)) == 0b1 and o2 == 0b0)
                Instruction{ .vector_bic = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"2s"
                    else
                        SIMDArrangement.@"4s",
                    .rd = rd,
                    .payload = .{ .shifted_imm = .{
                        .shift = @as(u6, @as(u2, @truncate(cmode >> 1))) * 8,
                        .shift_ty = .lsl,
                        .imm = imm8,
                    } },
                } }
            else if (o1 == 0b1 and @as(u2, @truncate(cmode >> 2)) == 0b10 and
                @as(u1, @truncate(cmode)) == 0b0 and o2 == 0b0)
                Instruction{ .mvni = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"4h"
                    else
                        SIMDArrangement.@"8h",
                    .rd = rd,
                    .payload = .{ .shifted_imm = .{
                        .shift = @as(u6, @as(u1, @truncate(cmode >> 1))) * 8,
                        .shift_ty = .lsl,
                        .imm = imm8,
                    } },
                } }
            else if (o1 == 0b1 and @as(u2, @truncate(cmode >> 2)) == 0b10 and
                @as(u1, @truncate(cmode)) == 0b1 and o2 == 0b0)
                Instruction{ .vector_bic = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"4h"
                    else
                        SIMDArrangement.@"8h",
                    .rd = rd,
                    .payload = .{ .shifted_imm = .{
                        .shift = @as(u6, @as(u1, @truncate(cmode >> 1))) * 8,
                        .shift_ty = .lsl,
                        .imm = imm8,
                    } },
                } }
            else if (o1 == 0b1 and @as(u3, @truncate(cmode >> 1)) == 0b110 and o2 == 0b0)
                Instruction{ .mvni = SIMDDataProcInstr{
                    .arrangement_a = if (q == 0b0)
                        SIMDArrangement.@"2s"
                    else
                        SIMDArrangement.@"4s",
                    .rd = rd,
                    .payload = .{ .shifted_imm = .{
                        .shift = (@as(u6, @as(u1, @truncate(cmode))) + 1) * 8,
                        .shift_ty = .msl,
                        .imm = imm8,
                    } },
                } }
            else if (q == 0b0 and o1 == 0b1 and cmode == 0b1110 and o2 == 0b0)
                Instruction{ .movi = SIMDDataProcInstr{
                    .rd = Register.from(op, .d, false),
                    .payload = .{ .imm = imm },
                } }
            else if (q == 0b1 and o1 == 0b1 and cmode == 0b1110 and o2 == 0b0)
                Instruction{ .movi = SIMDDataProcInstr{
                    .arrangement_a = SIMDArrangement.@"2d",
                    .rd = rd,
                    .payload = .{ .imm = imm },
                } }
            else if (q == 0b1 and o1 == 0b1 and cmode == 0b1111 and o2 == 0b0)
                Instruction{ .vector_fmov = SIMDDataProcInstr{
                    .arrangement_a = SIMDArrangement.@"2d",
                    .rd = rd,
                    .payload = .{ .fp_imm = toFloatingPointConst(f64, a, b, c, d, e, f, g, h) },
                } }
            else
                error.Unallocated;
        } else if (matches(op0, "0b0xx0") and matches(op1, "0b10") and !matches(op2, "0b0000") and matches(op3, "0bxxxxxxxx1")) { // SIMD shift by immediate
            const q = @as(u1, @truncate(op >> 30));
            const u = @as(u1, @truncate(op >> 29));
            const opcode = @as(u5, @truncate(op >> 11));
            const immh = @as(u4, @truncate(op >> 19));
            const immb = @as(u3, @truncate(op >> 16));
            const immhimmb = @as(u8, immh) << 3 | immb;
            return if (opcode == 0b00000) blk: {
                const t = if (matches(immh, "0b0001") and q == 0b0)
                    SIMDArrangement.@"8b"
                else if (matches(immh, "0b0001") and q == 0b1)
                    SIMDArrangement.@"16b"
                else if (matches(immh, "0b001x") and q == 0b0)
                    SIMDArrangement.@"4h"
                else if (matches(immh, "0b001x") and q == 0b1)
                    SIMDArrangement.@"8h"
                else if (matches(immh, "0b01xx") and q == 0b0)
                    SIMDArrangement.@"2s"
                else if (matches(immh, "0b01xx") and q == 0b1)
                    SIMDArrangement.@"4s"
                else if (matches(immh, "0b1xxx") and q == 0b1)
                    SIMDArrangement.@"2d"
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    16 - immhimmb
                else if (matches(immh, "0b001x"))
                    32 - immhimmb
                else if (matches(immh, "0b01xx"))
                    64 - immhimmb
                else if (matches(immh, "0b1xxx"))
                    128 - immhimmb
                else
                    return error.Unallocated;
                const payload = SIMDDataProcInstr{
                    .arrangement_a = t,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .payload = .{ .shift = shift },
                };
                break :blk if (u == 0b0)
                    Instruction{ .sshr = payload }
                else
                    Instruction{ .ushr = payload };
            } else if (opcode == 0b00010) blk: {
                const t = if (matches(immh, "0b0001") and q == 0b0)
                    SIMDArrangement.@"8b"
                else if (matches(immh, "0b0001") and q == 0b1)
                    SIMDArrangement.@"16b"
                else if (matches(immh, "0b001x") and q == 0b0)
                    SIMDArrangement.@"4h"
                else if (matches(immh, "0b001x") and q == 0b1)
                    SIMDArrangement.@"8h"
                else if (matches(immh, "0b01xx") and q == 0b0)
                    SIMDArrangement.@"2s"
                else if (matches(immh, "0b01xx") and q == 0b1)
                    SIMDArrangement.@"4s"
                else if (matches(immh, "0b1xxx") and q == 0b1)
                    SIMDArrangement.@"2d"
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    16 - immhimmb
                else if (matches(immh, "0b001x"))
                    32 - immhimmb
                else if (matches(immh, "0b01xx"))
                    64 - immhimmb
                else if (matches(immh, "0b1xxx"))
                    128 - immhimmb
                else
                    return error.Unallocated;
                const payload = SIMDDataProcInstr{
                    .arrangement_a = t,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .payload = .{ .shift = shift },
                };
                break :blk if (u == 0b0)
                    Instruction{ .ssra = payload }
                else
                    Instruction{ .usra = payload };
            } else if (opcode == 0b00100) blk: {
                const t = if (matches(immh, "0b0001") and q == 0b0)
                    SIMDArrangement.@"8b"
                else if (matches(immh, "0b0001") and q == 0b1)
                    SIMDArrangement.@"16b"
                else if (matches(immh, "0b001x") and q == 0b0)
                    SIMDArrangement.@"4h"
                else if (matches(immh, "0b001x") and q == 0b1)
                    SIMDArrangement.@"8h"
                else if (matches(immh, "0b01xx") and q == 0b0)
                    SIMDArrangement.@"2s"
                else if (matches(immh, "0b01xx") and q == 0b1)
                    SIMDArrangement.@"4s"
                else if (matches(immh, "0b1xxx") and q == 0b1)
                    SIMDArrangement.@"2d"
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    16 - immhimmb
                else if (matches(immh, "0b001x"))
                    32 - immhimmb
                else if (matches(immh, "0b01xx"))
                    64 - immhimmb
                else if (matches(immh, "0b1xxx"))
                    128 - immhimmb
                else
                    return error.Unallocated;
                const payload = SIMDDataProcInstr{
                    .arrangement_a = t,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .payload = .{ .shift = shift },
                };
                break :blk if (u == 0b0)
                    Instruction{ .srshr = payload }
                else
                    Instruction{ .urshr = payload };
            } else if (opcode == 0b00110) blk: {
                const t = if (matches(immh, "0b0001") and q == 0b0)
                    SIMDArrangement.@"8b"
                else if (matches(immh, "0b0001") and q == 0b1)
                    SIMDArrangement.@"16b"
                else if (matches(immh, "0b001x") and q == 0b0)
                    SIMDArrangement.@"4h"
                else if (matches(immh, "0b001x") and q == 0b1)
                    SIMDArrangement.@"8h"
                else if (matches(immh, "0b01xx") and q == 0b0)
                    SIMDArrangement.@"2s"
                else if (matches(immh, "0b01xx") and q == 0b1)
                    SIMDArrangement.@"4s"
                else if (matches(immh, "0b1xxx") and q == 0b1)
                    SIMDArrangement.@"2d"
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    16 - immhimmb
                else if (matches(immh, "0b001x"))
                    32 - immhimmb
                else if (matches(immh, "0b01xx"))
                    64 - immhimmb
                else if (matches(immh, "0b1xxx"))
                    128 - immhimmb
                else
                    return error.Unallocated;
                const payload = SIMDDataProcInstr{
                    .arrangement_a = t,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .payload = .{ .shift = shift },
                };
                break :blk if (u == 0b0)
                    Instruction{ .srsra = payload }
                else
                    Instruction{ .ursra = payload };
            } else if (u == 0b0 and opcode == 0b01010) blk: {
                const t = if (matches(immh, "0b0001") and q == 0b0)
                    SIMDArrangement.@"8b"
                else if (matches(immh, "0b0001") and q == 0b1)
                    SIMDArrangement.@"16b"
                else if (matches(immh, "0b001x") and q == 0b0)
                    SIMDArrangement.@"4h"
                else if (matches(immh, "0b001x") and q == 0b1)
                    SIMDArrangement.@"8h"
                else if (matches(immh, "0b01xx") and q == 0b0)
                    SIMDArrangement.@"2s"
                else if (matches(immh, "0b01xx") and q == 0b1)
                    SIMDArrangement.@"4s"
                else if (matches(immh, "0b1xxx") and q == 0b1)
                    SIMDArrangement.@"2d"
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    immhimmb - 8
                else if (matches(immh, "0b001x"))
                    immhimmb - 16
                else if (matches(immh, "0b01xx"))
                    immhimmb - 32
                else if (matches(immh, "0b1xxx"))
                    immhimmb - 64
                else
                    return error.Unallocated;
                break :blk Instruction{ .shl = SIMDDataProcInstr{
                    .arrangement_a = t,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (opcode == 0b01110) blk: {
                const t = if (matches(immh, "0b0001") and q == 0b0)
                    SIMDArrangement.@"8b"
                else if (matches(immh, "0b0001") and q == 0b1)
                    SIMDArrangement.@"16b"
                else if (matches(immh, "0b001x") and q == 0b0)
                    SIMDArrangement.@"4h"
                else if (matches(immh, "0b001x") and q == 0b1)
                    SIMDArrangement.@"8h"
                else if (matches(immh, "0b01xx") and q == 0b0)
                    SIMDArrangement.@"2s"
                else if (matches(immh, "0b01xx") and q == 0b1)
                    SIMDArrangement.@"4s"
                else if (matches(immh, "0b1xxx") and q == 0b1)
                    SIMDArrangement.@"2d"
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    immhimmb - 8
                else if (matches(immh, "0b001x"))
                    immhimmb - 16
                else if (matches(immh, "0b01xx"))
                    immhimmb - 32
                else if (matches(immh, "0b1xxx"))
                    immhimmb - 64
                else
                    return error.Unallocated;
                const payload = SIMDDataProcInstr{
                    .arrangement_a = t,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .payload = .{ .shift = shift },
                };
                break :blk if (u == 0b0)
                    Instruction{ .sqshl = payload }
                else
                    Instruction{ .uqshl = payload };
            } else if (opcode == 0b10000) blk: {
                const t = if (matches(immh, "0b0001") and q == 0b0)
                    SIMDArrangement.@"8b"
                else if (matches(immh, "0b0001") and q == 0b1)
                    SIMDArrangement.@"16b"
                else if (matches(immh, "0b001x") and q == 0b0)
                    SIMDArrangement.@"4h"
                else if (matches(immh, "0b001x") and q == 0b1)
                    SIMDArrangement.@"8h"
                else if (matches(immh, "0b01xx") and q == 0b0)
                    SIMDArrangement.@"2s"
                else if (matches(immh, "0b01xx") and q == 0b1)
                    SIMDArrangement.@"4s"
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    16 - immhimmb
                else if (matches(immh, "0b001x"))
                    32 - immhimmb
                else if (matches(immh, "0b01xx"))
                    64 - immhimmb
                else
                    return error.Unallocated;
                const payload = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = t,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .payload = .{ .shift = shift },
                };
                break :blk if (u == 0b0)
                    Instruction{ .shrn = payload }
                else
                    Instruction{ .sqshrun = payload };
            } else if (u == 0b0 and opcode == 0b10001) blk: {
                const t = if (matches(immh, "0b0001") and q == 0b0)
                    SIMDArrangement.@"8b"
                else if (matches(immh, "0b0001") and q == 0b1)
                    SIMDArrangement.@"16b"
                else if (matches(immh, "0b001x") and q == 0b0)
                    SIMDArrangement.@"4h"
                else if (matches(immh, "0b001x") and q == 0b1)
                    SIMDArrangement.@"8h"
                else if (matches(immh, "0b01xx") and q == 0b0)
                    SIMDArrangement.@"2s"
                else if (matches(immh, "0b01xx") and q == 0b1)
                    SIMDArrangement.@"4s"
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    16 - immhimmb
                else if (matches(immh, "0b001x"))
                    32 - immhimmb
                else if (matches(immh, "0b01xx"))
                    64 - immhimmb
                else
                    return error.Unallocated;
                break :blk Instruction{ .rshrn = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = t,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (opcode == 0b10010) blk: {
                const t = if (matches(immh, "0b0001") and q == 0b0)
                    SIMDArrangement.@"8b"
                else if (matches(immh, "0b0001") and q == 0b1)
                    SIMDArrangement.@"16b"
                else if (matches(immh, "0b001x") and q == 0b0)
                    SIMDArrangement.@"4h"
                else if (matches(immh, "0b001x") and q == 0b1)
                    SIMDArrangement.@"8h"
                else if (matches(immh, "0b01xx") and q == 0b0)
                    SIMDArrangement.@"2s"
                else if (matches(immh, "0b01xx") and q == 0b1)
                    SIMDArrangement.@"4s"
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    16 - immhimmb
                else if (matches(immh, "0b001x"))
                    32 - immhimmb
                else if (matches(immh, "0b01xx"))
                    64 - immhimmb
                else
                    return error.Unallocated;
                const payload = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = t,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .payload = .{ .shift = shift },
                };
                break :blk if (u == 0b0)
                    Instruction{ .sqshrn = payload }
                else
                    Instruction{ .uqshrn = payload };
            } else if (opcode == 0b10011) blk: {
                const t = if (matches(immh, "0b0001") and q == 0b0)
                    SIMDArrangement.@"8b"
                else if (matches(immh, "0b0001") and q == 0b1)
                    SIMDArrangement.@"16b"
                else if (matches(immh, "0b001x") and q == 0b0)
                    SIMDArrangement.@"4h"
                else if (matches(immh, "0b001x") and q == 0b1)
                    SIMDArrangement.@"8h"
                else if (matches(immh, "0b01xx") and q == 0b0)
                    SIMDArrangement.@"2s"
                else if (matches(immh, "0b01xx") and q == 0b1)
                    SIMDArrangement.@"4s"
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    16 - immhimmb
                else if (matches(immh, "0b001x"))
                    32 - immhimmb
                else if (matches(immh, "0b01xx"))
                    64 - immhimmb
                else
                    return error.Unallocated;
                const payload = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = t,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .payload = .{ .shift = shift },
                };
                break :blk if (u == 0b0)
                    Instruction{ .sqrshrn = payload }
                else
                    Instruction{ .uqrshrn = payload };
            } else if (opcode == 0b10100) blk: {
                const t = if (matches(immh, "0b0001"))
                    SIMDArrangement.@"8h"
                else if (matches(immh, "0b001x"))
                    SIMDArrangement.@"4s"
                else if (matches(immh, "0b01xx"))
                    SIMDArrangement.@"2d"
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    immhimmb - 8
                else if (matches(immh, "0b001x"))
                    immhimmb - 16
                else if (matches(immh, "0b01xx"))
                    immhimmb - 32
                else
                    return error.Unallocated;
                const payload = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = t,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .payload = .{ .shift = shift },
                };
                break :blk if (u == 0b0)
                    Instruction{ .sshll = payload }
                else
                    Instruction{ .ushll = payload };
            } else if (opcode == 0b11100) blk: {
                const t = if (matches(immh, "0b001x") and q == 0b0)
                    SIMDArrangement.@"4h"
                else if (matches(immh, "0b001x") and q == 0b1)
                    SIMDArrangement.@"8h"
                else if (matches(immh, "0b01xx") and q == 0b0)
                    SIMDArrangement.@"2s"
                else if (matches(immh, "0b01xx") and q == 0b1)
                    SIMDArrangement.@"4s"
                else if (matches(immh, "0b1xxx") and q == 0b1)
                    SIMDArrangement.@"2d"
                else
                    return error.Unallocated;
                const fbits = if (matches(immh, "0b001x"))
                    32 - immhimmb
                else if (matches(immh, "0b01xx"))
                    64 - immhimmb
                else if (matches(immh, "0b1xxx"))
                    128 - immhimmb
                else
                    return error.Unallocated;
                const payload = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = t,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .payload = .{ .imm = fbits },
                };
                break :blk if (u == 0)
                    Instruction{ .vector_scvtf = payload }
                else
                    Instruction{ .vector_ucvtf = payload };
            } else if (opcode == 0b11111) blk: {
                const t = if (matches(immh, "0b001x") and q == 0b0)
                    SIMDArrangement.@"4h"
                else if (matches(immh, "0b001x") and q == 0b1)
                    SIMDArrangement.@"8h"
                else if (matches(immh, "0b01xx") and q == 0b0)
                    SIMDArrangement.@"2s"
                else if (matches(immh, "0b01xx") and q == 0b1)
                    SIMDArrangement.@"4s"
                else if (matches(immh, "0b1xxx") and q == 0b1)
                    SIMDArrangement.@"2d"
                else
                    return error.Unallocated;
                const fbits = if (matches(immh, "0b001x"))
                    32 - immhimmb
                else if (matches(immh, "0b01xx"))
                    64 - immhimmb
                else if (matches(immh, "0b1xxx"))
                    128 - immhimmb
                else
                    return error.Unallocated;
                const payload = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = t,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .payload = .{ .imm = fbits },
                };
                break :blk if (u == 0b0)
                    Instruction{ .vector_fcvtzs = payload }
                else
                    Instruction{ .vector_fcvtzu = payload };
            } else if (u == 0b1 and opcode == 0b01000) blk: {
                const t = if (matches(immh, "0b0001") and q == 0b0)
                    SIMDArrangement.@"8b"
                else if (matches(immh, "0b0001") and q == 0b1)
                    SIMDArrangement.@"16b"
                else if (matches(immh, "0b001x") and q == 0b0)
                    SIMDArrangement.@"4h"
                else if (matches(immh, "0b001x") and q == 0b1)
                    SIMDArrangement.@"8h"
                else if (matches(immh, "0b01xx") and q == 0b0)
                    SIMDArrangement.@"2s"
                else if (matches(immh, "0b01xx") and q == 0b1)
                    SIMDArrangement.@"4s"
                else if (matches(immh, "0b1xxx") and q == 0b1)
                    SIMDArrangement.@"2d"
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    16 - immhimmb
                else if (matches(immh, "0b001x"))
                    32 - immhimmb
                else if (matches(immh, "0b01xx"))
                    64 - immhimmb
                else if (matches(immh, "0b1xxx"))
                    128 - immhimmb
                else
                    return error.Unallocated;
                break :blk Instruction{ .sri = SIMDDataProcInstr{
                    .arrangement_a = t,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 0b1 and opcode == 0b01010) blk: {
                const t = if (matches(immh, "0b0001") and q == 0b0)
                    SIMDArrangement.@"8b"
                else if (matches(immh, "0b0001") and q == 0b1)
                    SIMDArrangement.@"16b"
                else if (matches(immh, "0b001x") and q == 0b0)
                    SIMDArrangement.@"4h"
                else if (matches(immh, "0b001x") and q == 0b1)
                    SIMDArrangement.@"8h"
                else if (matches(immh, "0b01xx") and q == 0b0)
                    SIMDArrangement.@"2s"
                else if (matches(immh, "0b01xx") and q == 0b1)
                    SIMDArrangement.@"4s"
                else if (matches(immh, "0b1xxx") and q == 0b1)
                    SIMDArrangement.@"2d"
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    immhimmb - 8
                else if (matches(immh, "0b001x"))
                    immhimmb - 16
                else if (matches(immh, "0b01xx"))
                    immhimmb - 32
                else if (matches(immh, "0b1xxx"))
                    immhimmb - 64
                else
                    return error.Unallocated;
                break :blk Instruction{ .sli = SIMDDataProcInstr{
                    .arrangement_a = t,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 0b1 and opcode == 0b01100) blk: {
                const t = if (matches(immh, "0b0001") and q == 0b0)
                    SIMDArrangement.@"8b"
                else if (matches(immh, "0b0001") and q == 0b1)
                    SIMDArrangement.@"16b"
                else if (matches(immh, "0b001x") and q == 0b0)
                    SIMDArrangement.@"4h"
                else if (matches(immh, "0b001x") and q == 0b1)
                    SIMDArrangement.@"8h"
                else if (matches(immh, "0b01xx") and q == 0b0)
                    SIMDArrangement.@"2s"
                else if (matches(immh, "0b01xx") and q == 0b1)
                    SIMDArrangement.@"4s"
                else if (matches(immh, "0b1xxx") and q == 0b1)
                    SIMDArrangement.@"2d"
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    immhimmb - 8
                else if (matches(immh, "0b001x"))
                    immhimmb - 16
                else if (matches(immh, "0b01xx"))
                    immhimmb - 32
                else if (matches(immh, "0b1xxx"))
                    immhimmb - 64
                else
                    return error.Unallocated;
                break :blk Instruction{ .sqshlu = SIMDDataProcInstr{
                    .arrangement_a = t,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 0b1 and opcode == 0b10001) blk: {
                const t = if (matches(immh, "0b0001") and q == 0b0)
                    SIMDArrangement.@"8b"
                else if (matches(immh, "0b0001") and q == 0b1)
                    SIMDArrangement.@"16b"
                else if (matches(immh, "0b001x") and q == 0b0)
                    SIMDArrangement.@"4h"
                else if (matches(immh, "0b001x") and q == 0b1)
                    SIMDArrangement.@"8h"
                else if (matches(immh, "0b01xx") and q == 0b0)
                    SIMDArrangement.@"2s"
                else if (matches(immh, "0b01xx") and q == 0b1)
                    SIMDArrangement.@"4s"
                else
                    return error.Unallocated;
                const shift = if (matches(immh, "0b0001"))
                    16 - immhimmb
                else if (matches(immh, "0b001x"))
                    32 - immhimmb
                else if (matches(immh, "0b01xx"))
                    64 - immhimmb
                else
                    return error.Unallocated;
                break :blk Instruction{ .sqrshrun = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = t,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .payload = .{ .shift = shift },
                } };
            } else if (u == 0b1 and opcode == 0b10011)
                Instruction{ .uqrshrn = undefined }
            else
                error.Unallocated;
        } else if (matches(op0, "0b0xx0") and matches(op1, "0b1x") and matches(op3, "0bxxxxxxxx0")) { // SIMD vector x indexed element
            const q = @as(u1, @truncate(op >> 30));
            const u = @as(u1, @truncate(op >> 29));
            const size = @as(u2, @truncate(op >> 22));
            const l = @as(u1, @truncate(op >> 21));
            const m = @as(u1, @truncate(op >> 20));
            const rm = @as(u4, @truncate(op >> 16));
            const h = @as(u1, @truncate(op >> 11));
            const sizeq = @as(u3, size) << 1 | q;
            const mrm = @as(u5, m) << 4 | rm;
            const sz = @as(u1, @truncate(size));
            const qsz = @as(u2, q) << 1 | sz;
            const szl = @as(u2, sz) << 1 | l;
            const opcode = @as(u4, @truncate(op >> 12));
            return if (u == 0b0 and opcode == 0b0010)
                Instruction{ .smlal = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = if (size == 0b01)
                        SIMDArrangement.@"4s"
                    else if (size == 0b10)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = if (size == 0b01)
                        Register.from(@as(u5, rm), .v, false)
                    else if (size == 0b10)
                        Register.from(mrm, .v, false)
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (size == 0b01)
                        @as(u3, h) << 2 | @as(u3, l) << 1 | m
                    else if (size == 0b10)
                        @as(u2, h) << 1 | l
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b0 and opcode == 0b0011)
                Instruction{ .sqdmlal = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = if (size == 0b01)
                        SIMDArrangement.@"4s"
                    else if (size == 0b10)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = if (size == 0b01)
                        Register.from(@as(u5, rm), .v, false)
                    else if (size == 0b10)
                        Register.from(mrm, .v, false)
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (size == 0b01)
                        @as(u3, h) << 2 | @as(u3, l) << 1 | m
                    else if (size == 0b10)
                        @as(u2, h) << 1 | l
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b0 and opcode == 0b0110)
                Instruction{ .smlsl = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = if (size == 0b01)
                        SIMDArrangement.@"4s"
                    else if (size == 0b10)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = if (size == 0b01)
                        Register.from(@as(u5, rm), .v, false)
                    else if (size == 0b10)
                        Register.from(mrm, .v, false)
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (size == 0b01)
                        @as(u3, h) << 2 | @as(u3, l) << 1 | m
                    else if (size == 0b10)
                        @as(u2, h) << 1 | l
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b0 and opcode == 0b0111)
                Instruction{ .sqdmlsl = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = if (size == 0b01)
                        SIMDArrangement.@"4s"
                    else if (size == 0b10)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = if (size == 0b01)
                        Register.from(@as(u5, rm), .v, false)
                    else if (size == 0b10)
                        Register.from(mrm, .v, false)
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (size == 0b01)
                        @as(u3, h) << 2 | @as(u3, l) << 1 | m
                    else if (size == 0b10)
                        @as(u2, h) << 1 | l
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b0 and opcode == 0b1000)
                Instruction{ .mul = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b010)
                        SIMDArrangement.@"4h"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"8h"
                    else if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else
                        return error.Unallocated,
                    .rm = if (size == 0b01)
                        Register.from(@as(u5, rm), .v, false)
                    else if (size == 0b10)
                        Register.from(mrm, .v, false)
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (size == 0b01)
                        @as(u3, h) << 2 | @as(u3, l) << 1 | m
                    else if (size == 0b10)
                        @as(u2, h) << 1 | l
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b0 and opcode == 0b1010)
                Instruction{ .smull = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = if (size == 0b01)
                        SIMDArrangement.@"4s"
                    else if (size == 0b10)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = if (size == 0b01)
                        Register.from(@as(u5, rm), .v, false)
                    else if (size == 0b10)
                        Register.from(mrm, .v, false)
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (size == 0b01)
                        @as(u3, h) << 2 | @as(u3, l) << 1 | m
                    else if (size == 0b10)
                        @as(u2, h) << 1 | l
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b0 and opcode == 0b1011)
                Instruction{ .sqdmull = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = if (size == 0b01)
                        SIMDArrangement.@"4s"
                    else if (size == 0b10)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = if (size == 0b01)
                        Register.from(@as(u5, rm), .v, false)
                    else if (size == 0b10)
                        Register.from(mrm, .v, false)
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (size == 0b01)
                        @as(u3, h) << 2 | @as(u3, l) << 1 | m
                    else if (size == 0b10)
                        @as(u2, h) << 1 | l
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b0 and opcode == 0b1100)
                Instruction{ .sqdmulh = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b010)
                        SIMDArrangement.@"4h"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"8h"
                    else if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else
                        return error.Unallocated,
                    .rm = if (size == 0b01)
                        Register.from(@as(u5, rm), .v, false)
                    else if (size == 0b10)
                        Register.from(mrm, .v, false)
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (size == 0b01)
                        @as(u3, h) << 2 | @as(u3, l) << 1 | m
                    else if (size == 0b10)
                        @as(u2, h) << 1 | l
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b0 and opcode == 0b1101)
                Instruction{ .sqrdmulh = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b010)
                        SIMDArrangement.@"4h"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"8h"
                    else if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else
                        return error.Unallocated,
                    .rm = if (size == 0b01)
                        Register.from(@as(u5, rm), .v, false)
                    else if (size == 0b10)
                        Register.from(mrm, .v, false)
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (size == 0b01)
                        @as(u3, h) << 2 | @as(u3, l) << 1 | m
                    else if (size == 0b10)
                        @as(u2, h) << 1 | l
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b0 and opcode == 0b1111)
                Instruction{ .sudot = undefined }
            else if (u == 0b0 and size == 0b01 and opcode == 0b1111)
                Instruction{ .bfdot = undefined }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b0001)
                Instruction{ .fmla = SIMDDataProcInstr{
                    .arrangement_a = if (qsz == 0b00)
                        SIMDArrangement.@"2s"
                    else if (qsz == 0b10)
                        SIMDArrangement.@"4s"
                    else if (qsz == 0b11)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = Register.from(mrm, .v, false),
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (matches(szl, "0b0x"))
                        @as(u2, h) << 1 | l
                    else if (szl == 0b10)
                        h
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b0101)
                Instruction{ .fmls = SIMDDataProcInstr{
                    .arrangement_a = if (qsz == 0b00)
                        SIMDArrangement.@"2s"
                    else if (qsz == 0b10)
                        SIMDArrangement.@"4s"
                    else if (qsz == 0b11)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = Register.from(mrm, .v, false),
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (matches(szl, "0b0x"))
                        @as(u2, h) << 1 | l
                    else if (szl == 0b10)
                        h
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b0 and size >= 0b10 and opcode == 0b1001)
                Instruction{ .vector_fmul = SIMDDataProcInstr{
                    .arrangement_a = if (qsz == 0b00)
                        SIMDArrangement.@"2s"
                    else if (qsz == 0b10)
                        SIMDArrangement.@"4s"
                    else if (qsz == 0b11)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = Register.from(mrm, .v, false),
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (matches(szl, "0b0x"))
                        @as(u2, h) << 1 | l
                    else if (szl == 0b10)
                        h
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b0 and size == 0b10 and opcode == 0b0000)
                Instruction{ .fmlal = undefined }
            else if (u == 0b0 and size == 0b10 and opcode == 0b0100)
                Instruction{ .fmlsl = undefined }
            else if (u == 0b0 and size == 0b10 and opcode == 0b1111)
                Instruction{ .usdot = undefined }
            else if (u == 0b0 and size == 0b11 and opcode == 0b1111)
                Instruction{ .bfmlalb = undefined }
            else if (u == 0b1 and opcode == 0b0000)
                Instruction{ .mla = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b010)
                        SIMDArrangement.@"4h"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"8h"
                    else if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else
                        return error.Unallocated,
                    .rm = if (size == 0b01)
                        Register.from(@as(u5, rm), .v, false)
                    else if (size == 0b10)
                        Register.from(mrm, .v, false)
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (size == 0b01)
                        @as(u3, h) << 2 | @as(u3, l) << 1 | m
                    else if (size == 0b10)
                        @as(u2, h) << 1 | l
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b1 and opcode == 0b0010)
                Instruction{ .umlal = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = if (size == 0b01)
                        SIMDArrangement.@"4s"
                    else if (size == 0b10)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = if (size == 0b01)
                        Register.from(@as(u5, rm), .v, false)
                    else if (size == 0b10)
                        Register.from(mrm, .v, false)
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (size == 0b01)
                        @as(u3, h) << 2 | @as(u3, l) << 1 | m
                    else if (size == 0b10)
                        @as(u2, h) << 1 | l
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b1 and opcode == 0b0100)
                Instruction{ .mls = SIMDDataProcInstr{
                    .arrangement_a = if (sizeq == 0b010)
                        SIMDArrangement.@"4h"
                    else if (sizeq == 0b011)
                        SIMDArrangement.@"8h"
                    else if (sizeq == 0b100)
                        SIMDArrangement.@"2s"
                    else if (sizeq == 0b101)
                        SIMDArrangement.@"4s"
                    else
                        return error.Unallocated,
                    .rm = if (size == 0b01)
                        Register.from(@as(u5, rm), .v, false)
                    else if (size == 0b10)
                        Register.from(mrm, .v, false)
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (size == 0b01)
                        @as(u3, h) << 2 | @as(u3, l) << 1 | m
                    else if (size == 0b10)
                        @as(u2, h) << 1 | l
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b1 and opcode == 0b0110)
                Instruction{ .umlsl = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = if (size == 0b01)
                        SIMDArrangement.@"4s"
                    else if (size == 0b10)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = if (size == 0b01)
                        Register.from(@as(u5, rm), .v, false)
                    else if (size == 0b10)
                        Register.from(mrm, .v, false)
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (size == 0b01)
                        @as(u3, h) << 2 | @as(u3, l) << 1 | m
                    else if (size == 0b10)
                        @as(u2, h) << 1 | l
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b1 and opcode == 0b1010)
                Instruction{ .umull = SIMDDataProcInstr{
                    .q = q == 1,
                    .arrangement_a = if (size == 0b01)
                        SIMDArrangement.@"4s"
                    else if (size == 0b10)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = if (size == 0b01)
                        Register.from(@as(u5, rm), .v, false)
                    else if (size == 0b10)
                        Register.from(mrm, .v, false)
                    else
                        return error.Unallocated,
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (size == 0b01)
                        @as(u3, h) << 2 | @as(u3, l) << 1 | m
                    else if (size == 0b10)
                        @as(u2, h) << 1 | l
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b1 and opcode == 0b1101)
                Instruction{ .sqrdmlah = undefined }
            else if (u == 0b1 and opcode == 0b1110)
                Instruction{ .udot = undefined }
            else if (u == 0b1 and opcode == 0b1111)
                Instruction{ .sqrdmlsh = undefined }
            else if (u == 0b1 and size == 0b00 and opcode == 0b1001)
                Instruction{ .fmulx = undefined }
            else if (u == 0b1 and size == 0b01 and @as(u1, @truncate(opcode >> 3)) == 0b0 and @as(u1, @truncate(opcode)) == 0b1)
                Instruction{ .fcmla = undefined }
            else if (u == 0b1 and size >= 0b10 and opcode == 0b1001)
                Instruction{ .fmulx = SIMDDataProcInstr{
                    .arrangement_a = if (qsz == 0b00)
                        SIMDArrangement.@"2s"
                    else if (qsz == 0b10)
                        SIMDArrangement.@"4s"
                    else if (qsz == 0b11)
                        SIMDArrangement.@"2d"
                    else
                        return error.Unallocated,
                    .rm = Register.from(mrm, .v, false),
                    .rn = Register.from(op >> 5, .v, false),
                    .rd = Register.from(op, .v, false),
                    .post_index = if (matches(szl, "0b0x"))
                        @as(u2, h) << 1 | l
                    else if (szl == 0b10)
                        h
                    else
                        return error.Unallocated,
                } }
            else if (u == 0b1 and size == 0b10 and @as(u1, @truncate(opcode >> 3)) == 0b0 and @as(u1, @truncate(opcode)) == 0b1)
                Instruction{ .fcmla = undefined }
            else if (u == 0b1 and size == 0b10 and opcode == 0b1000)
                Instruction{ .fmlal = undefined }
            else if (u == 0b1 and size == 0b10 and opcode == 0b1100)
                Instruction{ .fmlsl = undefined }
            else
                error.Unallocated;
        } else if (matches(op0, "0b1100") and matches(op1, "0b00") and matches(op2, "0b10xx") and matches(op3, "0bxxx10xxxx")) { // Crypto three reg, imm2
            return error.Unimplemented;
        } else if (matches(op0, "0b1100") and matches(op1, "0b00") and matches(op2, "0b11xx") and matches(op3, "0bxxx1x00xx")) { // Crypto three reg, sha512
            return error.Unimplemented;
        } else if (matches(op0, "0b1100") and matches(op1, "0b00") and matches(op3, "0bxxx0xxxxx")) { // Crypto four reg
            return error.Unimplemented;
        } else if (matches(op0, "0b1100") and matches(op1, "0b01") and matches(op2, "0b00xx")) { // Xar
            return error.Unimplemented;
        } else if (matches(op0, "0b1100") and matches(op1, "0b01") and matches(op2, "0b1000") and matches(op3, "0b0001000xx")) { // Crypto two reg, sha512
            return error.Unimplemented;
        } else if (matches(op0, "0bx0x1") and matches(op1, "0b0x") and matches(op2, "0bx0xx")) { // Conversion between floating-point and fixed-point
            const sf = @as(u1, @truncate(op >> 31));
            const s = @as(u1, @truncate(op >> 29));
            const ptype = @as(u2, @truncate(op >> 22));
            const rmode = @as(u2, @truncate(op >> 19));
            const opcode = @as(u3, @truncate(op >> 16));
            const scale = @as(u6, @truncate(op >> 10));
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
                .fbits = @as(u6, @truncate(op >> 10)),
            };
            const to_float_payload = CvtInstr{
                .rd = Register.from(op, rn_width, false),
                .rn = Register.from(op >> 5, rd_width, false),
                .fbits = @as(u6, @truncate(op >> 10)),
            };
            return if ((sf == 0b0 and scale <= 0b011111) or
                s == 0b1 or ptype == 0b10 or opcode >= 0b100 or
                (@as(u1, @truncate(rmode)) == 0b0 and @as(u2, @truncate(opcode >> 1)) == 0b00) or
                (@as(u1, @truncate(rmode)) == 0b1 and @as(u2, @truncate(opcode >> 1)) == 0b01) or
                (@as(u1, @truncate(rmode >> 1)) == 0b0 and @as(u2, @truncate(opcode >> 1)) == 0b00) or
                (@as(u1, @truncate(rmode >> 1)) == 0b1 and @as(u2, @truncate(opcode >> 1)) == 0b01))
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
        } else if (matches(op0, "0bx0x1") and matches(op1, "0b0x") and matches(op2, "0bx1xx") and matches(op3, "0bxxx000000")) { // Conversion between floating point and integer
            const sf = @as(u1, @truncate(op >> 31));
            const s = @as(u1, @truncate(op >> 29));
            const ptype = @as(u2, @truncate(op >> 22));
            const rmode = @as(u2, @truncate(op >> 19));
            const opcode = @as(u3, @truncate(op >> 16));
            return if ((@as(u1, @truncate(rmode)) == 0b1 and @as(u2, @truncate(opcode >> 1)) == 0b01) or
                (@as(u1, @truncate(rmode)) == 0b1 and @as(u2, @truncate(opcode >> 1)) == 0b10) or
                (@as(u1, @truncate(rmode >> 1)) == 0b1 and @as(u2, @truncate(opcode >> 1)) == 0b01) or
                (@as(u1, @truncate(rmode >> 1)) == 0b1 and @as(u2, @truncate(opcode >> 1)) == 0b10) or
                (s == 0b0 and ptype == 0b10 and @as(u1, @truncate(opcode >> 2)) == 0b0) or
                (s == 0b0 and ptype == 0b10 and @as(u2, @truncate(opcode >> 1)) == 0b10) or
                (s == 0b1) or
                (sf == 0b0 and s == 0b0 and ptype == 0b00 and @as(u1, @truncate(rmode)) == 0b1 and @as(u2, @truncate(opcode >> 1)) == 0b11) or
                (sf == 0b0 and s == 0b0 and ptype == 0b00 and @as(u1, @truncate(rmode >> 1)) == 0b1 and @as(u2, @truncate(opcode >> 1)) == 0b11) or
                (sf == 0b0 and s == 0b0 and ptype == 0b01 and @as(u1, @truncate(rmode >> 1)) == 0b0 and @as(u2, @truncate(opcode >> 1)) == 0b11) or
                (sf == 0b0 and s == 0b0 and ptype == 0b01 and rmode == 0b10 and @as(u2, @truncate(opcode >> 1)) == 0b11) or
                (sf == 0b0 and s == 0b0 and ptype == 0b01 and rmode == 0b11 and opcode == 0b111) or
                (sf == 0b0 and s == 0b0 and ptype == 0b10 and @as(u2, @truncate(opcode >> 1)) == 0b11) or
                (sf == 0b1 and s == 0b0 and ptype == 0b00 and @as(u2, @truncate(opcode >> 1)) == 0b11) or
                (sf == 0b1 and s == 0b0 and ptype == 0b01 and @as(u1, @truncate(rmode)) == 0b1 and @as(u2, @truncate(opcode >> 1)) == 0b11) or
                (sf == 0b1 and s == 0b0 and ptype == 0b01 and @as(u1, @truncate(rmode >> 1)) == 0b1 and @as(u2, @truncate(opcode >> 1)) == 0b11) or
                (sf == 0b1 and s == 0b0 and ptype == 0b10 and @as(u1, @truncate(rmode)) == 0b0 and @as(u2, @truncate(opcode >> 1)) == 0b11) or
                (sf == 0b1 and s == 0b0 and ptype == 0b10 and @as(u1, @truncate(rmode >> 1)) == 0b1 and @as(u2, @truncate(opcode >> 1)) == 0b11))
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
        } else if (matches(op0, "0bx0x1") and matches(op1, "0b0x") and matches(op2, "0bx1xx") and matches(op3, "0bxxxx10000")) { // Floating-point data processing (1 source)
            const m = @as(u1, @truncate(op >> 31));
            const s = @as(u1, @truncate(op >> 29));
            const ptype = @as(u2, @truncate(op >> 22));
            const opcode = @as(u6, @truncate(op >> 15));
            const ftype_width = switch (ptype) {
                0b00 => Width.s,
                0b01 => Width.d,
                0b11 => Width.h,
                else => unreachable,
            };
            const opc_width = switch (@as(u2, @truncate(opcode))) {
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
        } else if (matches(op0, "0bx0x1") and matches(op1, "0b0x") and matches(op2, "0bx1xx") and matches(op3, "0bxxxxx1000")) // Floating-point compare
        {
            const m = @as(u1, @truncate(op >> 31));
            const s = @as(u1, @truncate(op >> 29));
            const ftype = @as(u2, @truncate(op >> 22));
            const o1 = @as(u2, @truncate(op >> 14));
            const opc = @as(u1, @truncate(op >> 3));
            const opcode2 = @as(u5, @truncate(op));
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
            return if (m == 0b1 or s == 0b1 or ftype == 0b10 or o1 != 0b00 or @as(u3, @truncate(opcode2)) != 0b00)
                error.Unallocated
            else
                Instruction{ .fcmp = payload };
        } else if (matches(op0, "0bx0x1") and matches(op1, "0b0x") and matches(op2, "0bx1xx") and matches(op3, "0bxxxxxx100")) { // Floating-point immediate
            const m = @as(u1, @truncate(op >> 31));
            const s = @as(u1, @truncate(op >> 29));
            const ptype = @as(u2, @truncate(op >> 22));
            const imm5 = @as(u5, @truncate(op >> 5));
            const imm8 = @as(u8, @truncate(op >> 13));
            const a = @as(u1, @truncate(imm8 >> 7));
            const b = @as(u1, @truncate(imm8 >> 6));
            const c = @as(u1, @truncate(imm8 >> 5));
            const d = @as(u1, @truncate(imm8 >> 4));
            const e = @as(u1, @truncate(imm8 >> 3));
            const f = @as(u1, @truncate(imm8 >> 2));
            const g = @as(u1, @truncate(imm8 >> 1));
            const h = @as(u1, @truncate(imm8));
            const rd_width = switch (ptype) {
                0b00 => Width.s,
                0b01 => Width.d,
                0b11 => Width.h,
                else => unreachable,
            };
            const fp_const = switch (rd_width) {
                .h => @as(f64, @floatCast(toFloatingPointConst(f16, a, b, c, d, e, f, g, h))),
                .s => @as(f64, @floatCast(toFloatingPointConst(f32, a, b, c, d, e, f, g, h))),
                .d => toFloatingPointConst(f64, a, b, c, d, e, f, g, h),
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
        } else if (matches(op0, "0bx0x1") and matches(op1, "0b0x") and matches(op2, "0bx1xx") and matches(op3, "0bxxxxxxx01")) { // Floating-point conditional compare
            const m = @as(u1, @truncate(op >> 31));
            const s = @as(u1, @truncate(op >> 29));
            const ftype = @as(u2, @truncate(op >> 22));
            const o1 = @as(u1, @truncate(op >> 4));
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
                .nzcv = @as(u4, @truncate(op)),
                .cond = @enumFromInt(@as(u4, @truncate(op >> 12))),
            };
            return if (m == 0b1 or s == 0b1 or ftype == 0b10)
                error.Unallocated
            else
                Instruction{ .fccmp = payload };
        } else if (matches(op0, "0bx0x1") and matches(op1, "0b0x") and matches(op2, "0bx1xx") and matches(op3, "0bxxxxxxx10")) { // Floating-point data processing (2 source)
            const m = @as(u1, @truncate(op >> 31));
            const s = @as(u1, @truncate(op >> 29));
            const ptype = @as(u2, @truncate(op >> 22));
            const opcode = @as(u4, @truncate(op >> 12));
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
        } else if (matches(op0, "0bx0x1") and matches(op1, "0b0x") and matches(op2, "0bx1xx") and matches(op3, "0bxxxxxxx11")) { // Floating-point conditional select
            const m = @as(u1, @truncate(op >> 31));
            const s = @as(u1, @truncate(op >> 29));
            const ftype = @as(u2, @truncate(op >> 22));
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
                .cond = @enumFromInt(@as(u4, @truncate(op >> 12))),
            };
            return if (m == 0b1 or s == 0b1 or ftype == 0b10)
                error.Unallocated
            else
                Instruction{ .fcsel = payload };
        } else if (matches(op0, "0bx0x1") and matches(op1, "0b1x")) {
            const m = @as(u1, @truncate(op >> 31));
            const s = @as(u1, @truncate(op >> 29));
            const ptype = @as(u2, @truncate(op >> 22));
            const o1 = @as(u1, @truncate(op >> 21));
            const o0 = @as(u1, @truncate(op >> 15));
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

fn toFloatingPointConst(comptime T: type, a: u1, b: u1, c: u1, d: u1, e: u1, f: u1, g: u1, h: u1) T {
    return switch (T) {
        f16 => @bitCast(0 |
            @as(u16, a) << 15 |
            @as(u16, ~b) << 14 |
            @as(u16, b) << 13 |
            @as(u16, b) << 12 |
            @as(u16, c) << 11 |
            @as(u16, d) << 10 |
            @as(u16, e) << 9 |
            @as(u16, f) << 8 |
            @as(u16, g) << 7 |
            @as(u16, h) << 6),
        f32 => @bitCast(0 |
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
            @as(u32, h) << 19),
        f64 => @bitCast(0 |
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
        else => @compileError("Invalid return type passed to toFloatingPointConst"),
    };
}
