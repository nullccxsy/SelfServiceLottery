module self_service_lottery::self_service_lottery {
    use sui::sui::SUI;
    use sui::balance::{self, Balance};
    use sui::coin::{self, Coin};
    use sui::package::{self, Publisher};
    use sui::event;
    use std::bcs;
    use sui::hmac::hmac_sha3_256;
    use std::string::{self, String};
    use sui::table::{self, Table};
    use sui::object::{self, ID, UID};
    use sui::transfer;
    use sui::context::TxContext;

    // ====== error code ======
    const ENotIncome: u64 = 0;
    const ENotCorrectLotteryID: u64 = 1;
    const EHasBeenEnded: u64 = 2;
    const ENotEnded: u64 = 3;
    const ENotRedeem: u64 = 4;
    const ENotBonus: u64 = 5;
    const ENotEnoughCoin: u64 = 6;
    const ENotOpenLottery: u64 = 7;

    // ====== struct ======
    public struct SELF_SERVICE_LOTTERY has drop {}

    public struct LotterySystem has key {
        id: UID,
        lotteries: Table<ID, Lottery>,
        ls_income: Balance<SUI>,
    }

    public struct Lottery has store {
        lottery_name: String,
        price: u64,
        total_amount: u64,
        remaining_amount: u64,
        end_epoch: u64,
        bonus: Balance<SUI>,
        announcement: bool,
        winner_code: vector<u8>,
        income: Balance<SUI>,
        creator: address,
    }

    public struct LotteryStub has key {
        id: UID,
        lottery_id: ID,
        code: vector<u8>,
    }

    public struct NewLotteryEvent has copy, drop {
        lottery_id: ID,
        lottery_name: String,
        price: u64,
        total_amount: u64,
        end_epoch: u64,
        bonus_value: u64,
    }

    public struct WinEvent has copy, drop {
        lottery_name: String,
        winner_code: vector<u8>,
    }

    public struct EndEvent has copy, drop {
        hint: String,
    }

    // ====== function ======
    public fun init(ctx: &mut TxContext) {
        // Generate LotterySystem and share it
        transfer::share_object(LotterySystem {
            id: object::new(ctx),
            lotteries: table::new<ID, Lottery>(ctx),
            ls_income: balance::zero(),
        });
    }

    entry fun withdraw(_: &Publisher, lottery_system: &mut LotterySystem, ctx: &mut TxContext) {
        // Check coin value
        let amount = lottery_system.ls_income.value();
        assert!(amount > 0, ENotIncome);
        // Withdraw income
        transfer::public_transfer(coin::from_balance(lottery_system.ls_income.split(amount), ctx), ctx.sender());
    }

    entry fun create_lottery(lottery_system: &mut LotterySystem, lottery_name: String, price: u64, total_amount: u64, bonus: Coin<SUI>, ctx: &mut TxContext) {
        // Default continuous 15 epoch
        create_lottery_with_epoch(lottery_system, lottery_name, price, total_amount, 15, bonus, ctx);
    }

    entry fun create_lottery_with_epoch(lottery_system: &mut LotterySystem, lottery_name: String, price: u64, total_amount: u64, continuous_epoch: u64, bonus: Coin<SUI>, ctx: &mut TxContext) {
        // Check bonus value
        assert!(bonus.value() > 0, ENotBonus);
        // Generate Lottery ID
        let lottery_id = object::id_from_address(ctx.fresh_object_address());
        // Generate Lottery
        let lottery = Lottery {
            lottery_name,
            price,
            total_amount,
            remaining_amount: total_amount,
            end_epoch: ctx.epoch() + continuous_epoch,
            bonus: bonus.into_balance(),
            announcement: false,
            winner_code: vector<u8>::empty(),
            income: balance::zero(),
            creator: ctx.sender(),
        };
        // Emit event
        event::emit(NewLotteryEvent {
            lottery_id,
            lottery_name: lottery.lottery_name.clone(),
            price,
            total_amount,
            end_epoch: ctx.epoch() + continuous_epoch,
            bonus_value: lottery.bonus.value(),
        });
        // Store it
        lottery_system.lotteries.add(lottery_id, lottery);
    }

    fun destroy_lottery(lottery: Lottery, ctx: &mut TxContext) {
        let Lottery {
            lottery_name: _,
            price: _,
            total_amount: _,
            remaining_amount: _,
            end_epoch: _,
            bonus,
            announcement: _,
            mut winner_code,
            mut income,
            creator,
        } = lottery;

        // Destroy winner_code
        while (winner_code.length() > 0) {
            winner_code.pop_back();
        };
        winner_code.destroy_empty();

        // Destroy bonus
        if (bonus.value() > 0) {
            income.join(bonus);
        } else {
            bonus.destroy_zero();
        };

        // Transfer income
        transfer::public_transfer(coin::from_balance(income, ctx), creator);
    }

    entry fun redeem_bonus(lottery_system: &mut LotterySystem, lottery_id: ID, ctx: &mut TxContext) {
        // Check lottery_id
        assert!(lottery_system.lotteries.contains(lottery_id), ENotCorrectLotteryID);
        // Get Lottery
        let mut lottery = lottery_system.lotteries.remove(lottery_id);
        // Check sales status and epoch
        assert!(lottery.total_amount == lottery.remaining_amount || ctx.epoch() > lottery.end_epoch + 15, ENotRedeem);
        calculate_fee(lottery_system, &mut lottery.income);
        destroy_lottery(lottery, ctx);
    }

    fun calculate(total: u64, remaining: u64, mut bytes: vector<u8>): u64 {
        let mut bytes1 = hmac_sha3_256(&bcs::to_bytes(&total), &bytes);
        bytes = hmac_sha3_256(&bcs::to_bytes(&remaining), &bytes1);
        // Destroy bytes1
        while (bytes1.length() > 0) {
            bytes1.pop_back();
        };
        bytes1.destroy_empty();
        // Calculate
        let mut index = 1;
        let d = total - remaining;
        while (bytes.length() > 0) {
            let byte = bytes.pop_back() as u64;
            index = (index * (byte % d + 1)) % d + 1;
        };
        // Destroy bytes
        bytes.destroy_empty();
        index
    }

    entry fun announcement(lottery_system: &mut LotterySystem, lottery_id: ID, ctx: &mut TxContext) {
        // Check lottery_id
        assert!(lottery_system.lotteries.contains(lottery_id), ENotCorrectLotteryID);
        // Get Lottery
        let lottery = &mut lottery_system.lotteries[lottery_id];
        // Check announcement
        assert!(!lottery.announcement, EHasBeenEnded);
        // Check epoch
        assert!(ctx.epoch() > lottery.end_epoch || lottery.remaining_amount == 0, ENotEnded);
        // Sell nothing
        if (lottery.total_amount == lottery.remaining_amount) {
            redeem_bonus(lottery_system, lottery_id, ctx);
            return;
        };
        // Random the winner
        lottery.announcement = true;
        let index = calculate(lottery.total_amount, lottery.remaining_amount, ctx.fresh_object_address().to_bytes());
        lottery.winner_code = hmac_sha3_256(&bcs::to_bytes(&index), &object::id_to_bytes(&lottery_id));
        // Emit event
        event::emit(WinEvent {
            lottery_name: lottery.lottery_name.clone(),
            winner_code: lottery.winner_code.clone(),
        });
    }

    entry fun buy_lottery(lottery_system: &mut LotterySystem, lottery_id: ID, mut sui: Coin<SUI>, ctx: &mut TxContext) {
        // Check lottery_id
        assert!(lottery_system.lotteries.contains(lottery_id), ENotCorrectLotteryID);
        // Get Lottery
        let lottery = &mut lottery_system.lotteries[lottery_id];
        // Check announcement
        assert!(!lottery.announcement, EHasBeenEnded);
        // Check sui value
        assert!(sui.value() >= lottery.price, ENotEnoughCoin);
        // Check epoch
        if (ctx.epoch() > lottery.end_epoch || lottery.remaining_amount == 0) {
            announcement(lottery_system, lottery_id, ctx);
            event::emit(EndEvent {
                hint: string::utf8(b"The lottery ticket you purchased has ended!"),
            });
            transfer::public_transfer(sui, ctx.sender());
            return;
        };
        // Deal with sui
        if (sui.value() == lottery.price) {
            lottery.income.join(sui.into_balance());
        } else {
            lottery.income.join(sui.split(lottery.price, ctx).into_balance());
            transfer::public_transfer(sui, ctx.sender());
        };
        // Update remaining amount and generate code
        lottery.remaining_amount = lottery.remaining_amount - 1;
        let index = lottery.total_amount - lottery.remaining_amount;
        let code = hmac_sha3_256(&bcs::to_bytes(&index), &object::id_to_bytes(&lottery_id));
        // Generate and transfer LotteryStub
        transfer::transfer(LotteryStub {
            id: object::new(ctx),
            lottery_id,
            code,
        }, ctx.sender());
        // Check sell out
        if (lottery.remaining_amount == 0) {
            announcement(lottery_system, lottery_id, ctx);
        };
    }

    fun destroy_lottery_stub(lottery_stub: LotteryStub) {
        let LotteryStub {
            id,
            lottery_id: _,
            mut code,
        } = lottery_stub;
        object::delete(id);
        while (code.length() > 0) {
            code.pop_back();
        };
        code.destroy_empty();
    }

    entry fun redeem_lottery(lottery_system: &mut LotterySystem, lottery_stub: LotteryStub, ctx: &mut TxContext) {
        // Get lottery id
        let lottery_id = lottery_stub.lottery_id;
        if (!lottery_system.lotteries.contains(lottery_id)) {
            destroy_lottery_stub(lottery_stub);
            event::emit(EndEvent {
                hint: string::utf8(b"You have not won a prize or the redemption period has expired!"),
            });
            return;
        };
        // Get lottery
        let lottery = &mut lottery_system.lotteries[lottery_id];
        if (!lottery.announcement && (ctx.epoch() > lottery.end_epoch || lottery.remaining_amount == 0)) {
            announcement(lottery_system, lottery_id, ctx);
            event::emit(EndEvent {
                hint: string::utf8(b"The lottery has just been drawn, please check and redeem again!"),
            });
            transfer::transfer(lottery_stub, ctx.sender());
            return;
        };
        // Check announcement
        assert!(lottery.announcement, ENotOpenLottery);
        // Check winner code
        if (lottery.winner_code == lottery_stub.code) {
            // Winner
            let amount = lottery.bonus.value();
            transfer::public_transfer(coin::from_balance(lottery.bonus.split(amount), ctx), ctx.sender());
            // Calculate fee amount (1%)
            calculate_fee(lottery_system, &mut lottery.income);
            destroy_lottery(lottery_system.lotteries.remove(lottery_id), ctx);
        } else {
            // Loser
            event::emit(EndEvent {
                hint: string::utf8(b"Unfortunately, the lottery you purchased did not win a prize!"),
            });
        };
        destroy_lottery_stub(lottery_stub);
    }

    fun calculate_fee(lottery_system: &mut LotterySystem, income: &mut Balance<SUI>) {
        // Calculate fee amount (1%)
        let amount = income.value() / 100;
        if (amount > 0) {
            lottery_system.ls_income.join(income.split(amount));
        };
    }

    // Additional functionality

    // Function to get details of a specific lottery
    public fun get_lottery_details(lottery_system: &LotterySystem, lottery_id: ID): Option<Lottery> {
        if (lottery_system.lotteries.contains(lottery_id)) {
            return Option::some(lottery_system.lotteries.get(lottery_id));
        }
        Option::none()
    }

    // Function to list all lotteries
    public fun list_all_lotteries(lottery_system: &LotterySystem): vector<Lottery> {
        let mut lotteries = vector<Lottery>::empty();
        let ids = lottery_system.lotteries.keys();
        for id in ids {
            let lottery = lottery_system.lotteries.get(id);
            lotteries.push_back(lottery);
        }
        lotteries
    }

    // Function to fetch all lottery stubs of a user
    public fun get_user_lottery_stubs(user: address, ctx: &TxContext): vector<LotteryStub> {
        let objects = object::list(user);
        let mut stubs = vector<LotteryStub>::empty();
        for obj in objects {
            if (object::type(obj) == type_of<LotteryStub>()) {
                let stub: LotteryStub = object::read(obj);
                stubs.push_back(stub);
            }
        }
        stubs
    }

    // Function to extend the duration of a lottery
    entry fun extend_lottery(lottery_system: &mut LotterySystem, lottery_id: ID, additional_epochs: u64, ctx: &mut TxContext) {
        // Check lottery_id
        assert!(lottery_system.lotteries.contains(lottery_id), ENotCorrectLotteryID);
        // Get Lottery
        let lottery = &mut lottery_system.lotteries[lottery_id];
        // Check if the lottery has ended
        assert!(!lottery.announcement, EHasBeenEnded);
        // Extend the lottery duration
        lottery.end_epoch = lottery.end_epoch + additional_epochs;
    }
}
