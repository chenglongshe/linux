// SPDX-License-Identifier: GPL-2.0
#include <linux/blkdev.h>
#include <linux/kunit/test.h>
#include <linux/numa.h>

static void blk_lib_discard_unsupported_returns_eopnotsupp(struct kunit *test)
{
	struct queue_limits lim = {
		.logical_block_size	= 512,
		.max_discard_sectors	= 0,
		.discard_granularity	= 0,
	};
	struct gendisk *disk;
	struct bio *bio = NULL;
	sector_t sector = 0;
	sector_t nr_sects = 8;
	int ret;

	disk = blk_alloc_disk(&lim, NUMA_NO_NODE);
	KUNIT_ASSERT_NOT_ERR_OR_NULL(test, disk);

	ret = __blkdev_issue_discard(disk->part0, sector, nr_sects,
				     GFP_KERNEL, &bio);

	KUNIT_EXPECT_EQ(test, ret, -EOPNOTSUPP);
	KUNIT_EXPECT_PTR_EQ(test, bio, NULL);

	put_disk(disk);
}

static struct kunit_case blk_lib_test_cases[] = {
	KUNIT_CASE(blk_lib_discard_unsupported_returns_eopnotsupp),
	{}
};

static struct kunit_suite blk_lib_test_suite = {
	.name = "blk-lib",
	.test_cases = blk_lib_test_cases,
};

kunit_test_suite(blk_lib_test_suite);

MODULE_DESCRIPTION("blk-lib KUnit tests");
MODULE_LICENSE("GPL");
