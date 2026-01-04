/***************************************************************************/

/*
 *  timers.c - Generic hardware timer support.
 *
 *  Copyright (C) 1993 Hamish Macdonald
 *  Copyright (C) 1999 D. Jeff Dionne
 *  Copyright (C) 2001 Georges Menie, Ken Desmet
 *
 * This file is subject to the terms and conditions of the GNU General Public
 * License.  See the file COPYING in the main directory of this archive
 * for more details.
 */

/***************************************************************************/

#include <linux/types.h>
#include <linux/kernel.h>
#include <linux/mm.h>
#include <linux/bitfield.h>
#include <linux/interrupt.h>
#include <linux/irq.h>
#include <linux/errno.h>
#include <linux/clocksource.h>
#include <linux/rtc.h>
#include <asm/setup.h>
#include <asm/machdep.h>
#include <asm/MC68VZ328.h>

#include "m68328.h"

/***************************************************************************/

#if defined(CONFIG_DRAGEN2)
/* with a 33.16 MHz clock, this will give usec resolution to the time functions */
#define CLOCK_SOURCE	TCTL_CLKSOURCE_SYSCLK
#define CLOCK_PRE	7
#define TICKS_PER_JIFFY	41450

#elif defined(CONFIG_XCOPILOT_BUGS)
/*
 * The only thing I know is that CLK32 is not available on Xcopilot
 * I have little idea about what frequency SYSCLK has on Xcopilot.
 * The values for prescaler and compare registers were simply
 * taken from the original source
 */
#define CLOCK_SOURCE	TCTL_CLKSOURCE_SYSCLK
#define CLOCK_PRE	2
#define TICKS_PER_JIFFY	0xd7e4

#else
/* default to using the 32Khz clock */
#define CLOCK_SOURCE	TCTL_CLKSOURCE_32KHZ
#define CLOCK_PRE	31
#define TICKS_PER_JIFFY	10
#endif

static u32 m68328_tick_cnt;

/***************************************************************************/

static irqreturn_t hw_tick(int irq, void *dummy)
{
	/* Reset Timer1 */
	TSTAT &= 0;

	m68328_tick_cnt += TICKS_PER_JIFFY;
	legacy_timer_tick(1);
	return IRQ_HANDLED;
}

/***************************************************************************/

static u64 m68328_read_clk(struct clocksource *cs)
{
	unsigned long flags;
	u32 cycles;

	local_irq_save(flags);
	cycles = m68328_tick_cnt + TCN;
	local_irq_restore(flags);

	return cycles;
}

/***************************************************************************/

static struct clocksource m68328_clk = {
	.name	= "timer",
	.rating	= 250,
	.read	= m68328_read_clk,
	.mask	= CLOCKSOURCE_MASK(32),
	.flags	= CLOCK_SOURCE_IS_CONTINUOUS,
};

/***************************************************************************/

void hw_timer_init(void)
{
	int ret;

	/* disable timer 1 */
	TCTL = 0;

	/* set ISR */
	ret = request_irq(TMR_IRQ_NUM, hw_tick, IRQF_TIMER, "timer", NULL);
	if (ret) {
		pr_err("Failed to request irq %d (timer): %pe\n", TMR_IRQ_NUM,
		       ERR_PTR(ret));
	}

	/* Restart mode, Enable int, Set clock source */
	TCTL = TCTL_OM | TCTL_IRQEN | CLOCK_SOURCE;
	TPRER = CLOCK_PRE;
	TCMP = TICKS_PER_JIFFY;

	/* Enable timer 1 */
	TCTL |= TCTL_TEN;
	clocksource_register_hz(&m68328_clk, TICKS_PER_JIFFY*HZ);
}

/***************************************************************************/

int m68328_hwclk(int set, struct rtc_time *t)
{
	u32 now;

	if (set) {
		if ((unsigned int)t->tm_hour >= 24 ||
		    (unsigned int)t->tm_min >= 60 ||
		    (unsigned int)t->tm_sec >= 60)
			return -EINVAL;

		now = FIELD_PREP(RTCTIME_HOURS_MASK, t->tm_hour) |
		      FIELD_PREP(RTCTIME_MINUTES_MASK, t->tm_min) |
		      FIELD_PREP(RTCTIME_SECONDS_MASK, t->tm_sec);
		RTCTIME = now;
		return 0;
	}

	now = RTCTIME;
	t->tm_year = 1;
	t->tm_mon = 0;
	t->tm_mday = 1;
	t->tm_hour = (now & RTCTIME_HOURS_MASK) >> RTCTIME_HOURS_SHIFT;
	t->tm_min = (now & RTCTIME_MINUTES_MASK) >> RTCTIME_MINUTES_SHIFT;
	t->tm_sec = (now & RTCTIME_SECONDS_MASK) >> RTCTIME_SECONDS_SHIFT;

	return 0;
}

/***************************************************************************/
