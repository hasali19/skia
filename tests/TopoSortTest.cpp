/*
 * Copyright 2015 Google Inc.
 *
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 */

#include "include/utils/SkRandom.h"
#include "src/gpu/ganesh/GrTTopoSort.h"
#include "tests/Test.h"

#include "tools/ToolUtils.h"

typedef void (*CreateGraphPF)(SkTArray<sk_sp<ToolUtils::TopoTestNode>>* graph);

/* Simple diamond
 *       3
 *      . .
 *     /   \
 *    1     2
 *    .     .
 *     \   /
 *       0
 */
static void create_graph0(SkTArray<sk_sp<ToolUtils::TopoTestNode>>* graph) {
    ToolUtils::TopoTestNode::AllocNodes(graph, 4);

    (*graph)[0]->dependsOn((*graph)[1].get());
    (*graph)[0]->dependsOn((*graph)[2].get());
    (*graph)[1]->dependsOn((*graph)[3].get());
    (*graph)[2]->dependsOn((*graph)[3].get());
}

/* Simple chain
 *     3
 *     ^
 *     |
 *     2
 *     ^
 *     |
 *     1
 *     ^
 *     |
 *     0
 */
static void create_graph1(SkTArray<sk_sp<ToolUtils::TopoTestNode>>* graph) {
    ToolUtils::TopoTestNode::AllocNodes(graph, 4);

    (*graph)[0]->dependsOn((*graph)[1].get());
    (*graph)[1]->dependsOn((*graph)[2].get());
    (*graph)[2]->dependsOn((*graph)[3].get());
}

/* Simple Loop
 *       2
 *      / .
 *     /   \
 *    .     \
 *    0 ---> 1
 */
static void create_graph2(SkTArray<sk_sp<ToolUtils::TopoTestNode>>* graph) {
    ToolUtils::TopoTestNode::AllocNodes(graph, 3);

    (*graph)[0]->dependsOn((*graph)[1].get());
    (*graph)[1]->dependsOn((*graph)[2].get());
    (*graph)[2]->dependsOn((*graph)[0].get());
}

/* Double diamond
 *       6
 *      . .
 *     /   \
 *    4     5
 *    .     .
 *     \   /
 *       3
 *      . .
 *     /   \
 *    1     2
 *    .     .
 *     \   /
 *       0
 */
static void create_graph3(SkTArray<sk_sp<ToolUtils::TopoTestNode>>* graph) {
    ToolUtils::TopoTestNode::AllocNodes(graph, 7);

    (*graph)[0]->dependsOn((*graph)[1].get());
    (*graph)[0]->dependsOn((*graph)[2].get());
    (*graph)[1]->dependsOn((*graph)[3].get());
    (*graph)[2]->dependsOn((*graph)[3].get());

    (*graph)[3]->dependsOn((*graph)[4].get());
    (*graph)[3]->dependsOn((*graph)[5].get());
    (*graph)[4]->dependsOn((*graph)[6].get());
    (*graph)[5]->dependsOn((*graph)[6].get());
}

/* Two independent diamonds
 *       3           7
 *      . .         . .
 *     /   \       /   \
 *    1     2     5     6
 *    .     .     .     .
 *     \   /       \   /
 *       0           4
 */
static void create_graph4(SkTArray<sk_sp<ToolUtils::TopoTestNode>>* graph) {
    ToolUtils::TopoTestNode::AllocNodes(graph, 8);

    (*graph)[0]->dependsOn((*graph)[1].get());
    (*graph)[0]->dependsOn((*graph)[2].get());
    (*graph)[1]->dependsOn((*graph)[3].get());
    (*graph)[2]->dependsOn((*graph)[3].get());

    (*graph)[4]->dependsOn((*graph)[5].get());
    (*graph)[4]->dependsOn((*graph)[6].get());
    (*graph)[5]->dependsOn((*graph)[7].get());
    (*graph)[6]->dependsOn((*graph)[7].get());
}

/* Two linked diamonds w/ two loops
 *       5     6
 *      / .   . \
 *     .   \ /   .
 *    2     3     4
 *     \    .    /
 *      .  / \  .
 *       0     1
 */
static void create_graph5(SkTArray<sk_sp<ToolUtils::TopoTestNode>>* graph) {
    ToolUtils::TopoTestNode::AllocNodes(graph, 7);

    (*graph)[0]->dependsOn((*graph)[3].get());
    (*graph)[1]->dependsOn((*graph)[3].get());
    (*graph)[2]->dependsOn((*graph)[0].get());
    (*graph)[3]->dependsOn((*graph)[5].get());
    (*graph)[3]->dependsOn((*graph)[6].get());
    (*graph)[4]->dependsOn((*graph)[1].get());
    (*graph)[5]->dependsOn((*graph)[2].get());
    (*graph)[6]->dependsOn((*graph)[4].get());
}

/* Two disjoint loops
 *       2          5
 *      / .        / .
 *     /   \      /   \
 *    .     \    .     \
 *    0 ---> 1   3 ---> 4
 */
static void create_graph6(SkTArray<sk_sp<ToolUtils::TopoTestNode>>* graph) {
    ToolUtils::TopoTestNode::AllocNodes(graph, 6);

    (*graph)[0]->dependsOn((*graph)[1].get());
    (*graph)[1]->dependsOn((*graph)[2].get());
    (*graph)[2]->dependsOn((*graph)[0].get());

    (*graph)[3]->dependsOn((*graph)[4].get());
    (*graph)[4]->dependsOn((*graph)[5].get());
    (*graph)[5]->dependsOn((*graph)[3].get());
}

DEF_TEST(TopoSort, reporter) {
    SkRandom rand;

    struct {
        CreateGraphPF fCreate;
        bool          fExpectedResult;
    } tests[] = {
        { create_graph0, true  },
        { create_graph1, true  },
        { create_graph2, false },
        { create_graph3, true  },
        { create_graph4, true  },
        { create_graph5, false },
        { create_graph6, false },
    };

    for (size_t i = 0; i < std::size(tests); ++i) {
        SkTArray<sk_sp<ToolUtils::TopoTestNode>> graph;

        (tests[i].fCreate)(&graph);

        const int numNodes = graph.count();

        ToolUtils::TopoTestNode::Shuffle(&graph, &rand);

        bool actualResult = GrTTopoSort<ToolUtils::TopoTestNode>(&graph);
        REPORTER_ASSERT(reporter, actualResult == tests[i].fExpectedResult);
        REPORTER_ASSERT(reporter, numNodes == graph.count());

        if (tests[i].fExpectedResult) {
            for (const auto& node : graph) {
                REPORTER_ASSERT(reporter, node->check());
            }
        } else {
            // When the topological sort fails all the nodes should still appear in the result
            // but their order can be somewhat arbitrary.
            std::vector<bool> seen(numNodes, false);

            for (const auto& node : graph) {
                SkASSERT(node);
                SkASSERT(!seen[node->id()]);
                seen[node->id()] = true;
            }
        }

        //SkDEBUGCODE(print(graph);)
    }
}
